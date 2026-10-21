/* SPDX-License-Identifier: MIT
 *
 * libtorment_crashtrace.so: an LD_PRELOAD library that records where a
 * process died from SIGSEGV, SIGBUS, SIGFPE, SIGILL or SIGABRT, so that crashes
 * of builds without a sanitizer can be told apart by stack.
 *
 * With TORMENT_CRASHTRACE_DIR=<dir> set, a fatal signal writes
 * <dir>/crash-<pid>.txt and the process then dies from the same signal with
 * the default action, so the parent's wait status (and any core dump) is the
 * same as without the library. With the variable unset, nothing is installed.
 *
 * File format (text, one record per line, read by nexus_harness.crashtrace):
 *   torment-crashtrace 1
 *   pid <pid>
 *   signal <signo>
 *   code <si_code>
 *   addr 0x<si_addr>
 *   unwound <1 if the faulting pc was found in the unwound stack, else 0>
 *   frame <i> 0x<pc> 0x<pc - module base> <module path, or ?>
 *   ...
 *   end
 * Frame 0 is the faulting pc (from the ucontext); the following frames are
 * return addresses. The module base is the start of the module's first
 * mapping (file offset 0) in /proc/self/maps, so the harness adds the ELF's
 * first PT_LOAD vaddr (0 for PIE/DSOs) to get an address for a symbolizer.
 *
 * Design
 *   - Installs a handler only where the disposition is still SIG_DFL when the
 *     library's constructor runs: a program (or a sanitizer runtime) with its
 *     own handler keeps it, and one that installs a handler later replaces
 *     ours. SA_RESETHAND puts SIG_DFL back on entry.
 *   - The handler runs on a static sigaltstack (main thread only, and only
 *     if none is set), so stack overflows in the main thread are traced.
 *   - Async-signal-safe: backtrace() is called once in the constructor so
 *     libgcc_s is loaded before any fault (under libfiu malloc faults a lazy
 *     dlopen in the handler could fail or deadlock). The handler then uses
 *     only backtrace(), raw syscalls (openat/read/write/close/tgkill: they
 *     bypass LD_PRELOAD wrappers such as libfiu's posix hooks and the
 *     torment-seed shim) and its own number formatting. No malloc, no stdio.
 *   - Re-raise: after writing, the handler sends the signal to its own
 *     thread with tgkill. It is blocked while the handler runs, so it is
 *     delivered on return with the default action and kills the process.
 *   - One trace per process: if several threads fault at once, only the
 *     first writes; the others re-raise straight away.
 *
 * Limits: threads other than the main one have no alternate stack, so their
 * stack overflows are not traced; a crash that corrupts the unwind path
 * yields just frame 0; static binaries are not covered (LD_PRELOAD).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

#define MAX_FRAMES 64
#define PATH_MAX_LEN 256

static char trace_dir[512];
static atomic_flag busy = ATOMIC_FLAG_INIT;
static char altstack[64 * 1024] __attribute__((aligned(16)));
static const int fatal_signals[] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT};

/* Handler state: static so that the handler needs very little stack. */
static uintptr_t frames[MAX_FRAMES];
static uintptr_t frame_base[MAX_FRAMES];
static char frame_mod[MAX_FRAMES][PATH_MAX_LEN];
static char out[MAX_FRAMES * (PATH_MAX_LEN + 64) + 512];
static size_t out_len;
static char line[4096 + PATH_MAX_LEN];

/* ---------- async-signal-safe output helpers ---------- */

static void put_str(const char *s) {
    while (*s && out_len < sizeof out - 1) out[out_len++] = *s++;
}

static void put_hex(uintptr_t v) {
    char tmp[2 + 2 * sizeof v];
    int n = 0;
    do {
        tmp[n++] = "0123456789abcdef"[v & 15];
        v >>= 4;
    } while (v);
    put_str("0x");
    while (n && out_len < sizeof out - 1) out[out_len++] = tmp[--n];
}

static void put_dec(long v) {
    char tmp[24];
    int n = 0;
    unsigned long u = v < 0 ? -(unsigned long)v : (unsigned long)v;
    do {
        tmp[n++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    if (v < 0) put_str("-");
    while (n && out_len < sizeof out - 1) out[out_len++] = tmp[--n];
}

static int parse_hex(const char **p, uintptr_t *v) {
    const char *s = *p;
    uintptr_t x = 0;
    int any = 0;
    for (;; s++) {
        int d;
        if (*s >= '0' && *s <= '9') d = *s - '0';
        else if (*s >= 'a' && *s <= 'f') d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') d = *s - 'A' + 10;
        else break;
        x = x * 16 + (uintptr_t)d;
        any = 1;
    }
    *p = s;
    *v = x;
    return any;
}

static void copy_path(char *dst, const char *src) {
    size_t i = 0;
    while (src[i] && src[i] != '\n' && i < PATH_MAX_LEN - 1) {
        dst[i] = src[i];
        i++;
    }
    dst[i] = 0;
}

/* ---------- /proc/self/maps ---------- */

/* One maps line: "start-end perms offset dev inode   path". */
static void maps_line(const char *s, int n, char *base_path, uintptr_t *base) {
    uintptr_t start, end, off, ino;
    const char *p = s;
    if (!parse_hex(&p, &start) || *p++ != '-' || !parse_hex(&p, &end)) return;
    while (*p == ' ') p++;
    while (*p && *p != ' ') p++; /* perms */
    while (*p == ' ') p++;
    if (!parse_hex(&p, &off)) return;
    while (*p == ' ') p++;
    while (*p && *p != ' ') p++; /* dev */
    while (*p == ' ') p++;
    parse_hex(&p, &ino); /* decimal, only skipped */
    while (*p && *p != ' ') p++;
    while (*p == ' ') p++;
    const char *path = *p ? p : "?";
    if (off == 0 && *p) {
        *base = start;
        copy_path(base_path, path);
    }
    for (int i = 0; i < n; i++) {
        if (frame_mod[i][0] || frames[i] < start || frames[i] >= end) continue;
        copy_path(frame_mod[i], path);
        /* A mapping whose file's offset-0 mapping we saw is relative to that
         * base; anything else (anonymous memory, JIT) is relative to itself. */
        frame_base[i] = strcmp(frame_mod[i], base_path) == 0 ? *base : start - off;
    }
}

static void resolve_modules(int n) {
    static char buf[4096];
    static char base_path[PATH_MAX_LEN];
    uintptr_t base = 0;
    size_t used = 0;
    base_path[0] = 0;
    long fd = syscall(SYS_openat, AT_FDCWD, "/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    for (;;) {
        long r = syscall(SYS_read, fd, buf, sizeof buf);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        for (long i = 0; i < r; i++) {
            char c = buf[i];
            if (c == '\n') {
                line[used] = 0;
                maps_line(line, n, base_path, &base);
                used = 0;
            } else if (used < sizeof line - 1) {
                line[used++] = c;
            }
        }
    }
    syscall(SYS_close, fd);
}

/* ---------- handler ---------- */

static uintptr_t context_pc(void *ucv) {
    ucontext_t *uc = ucv;
    if (!uc) return 0;
#if defined(__x86_64__)
    return (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
#elif defined(__i386__)
    return (uintptr_t)uc->uc_mcontext.gregs[REG_EIP];
#elif defined(__aarch64__)
    return (uintptr_t)uc->uc_mcontext.pc;
#elif defined(__riscv)
    return (uintptr_t)uc->uc_mcontext.__gregs[REG_PC];
#else
    return 0;
#endif
}

static void write_trace(int sig, siginfo_t *si, void *uc) {
    void *bt[MAX_FRAMES];
    int nbt = backtrace(bt, MAX_FRAMES);
    uintptr_t pc = context_pc(uc);
    int n = 0, unwound = 0;
    if (pc) frames[n++] = pc;
    for (int i = 0; i < nbt; i++) {
        if (pc && (uintptr_t)bt[i] == pc) {
            for (int j = i + 1; j < nbt && n < MAX_FRAMES; j++) frames[n++] = (uintptr_t)bt[j];
            unwound = 1;
            break;
        }
    }
    if (!unwound) /* keep everything; the harness drops this library's frames */
        for (int i = 0; i < nbt && n < MAX_FRAMES; i++) frames[n++] = (uintptr_t)bt[i];
    for (int i = 0; i < n; i++) {
        frame_mod[i][0] = 0;
        frame_base[i] = 0;
    }
    resolve_modules(n);

    long pid = syscall(SYS_getpid);
    out_len = 0;
    put_str("torment-crashtrace 1\npid ");
    put_dec(pid);
    put_str("\nsignal ");
    put_dec(sig);
    put_str("\ncode ");
    put_dec(si ? si->si_code : 0);
    put_str("\naddr ");
    put_hex(si ? (uintptr_t)si->si_addr : 0);
    put_str("\nunwound ");
    put_dec(unwound);
    put_str("\n");
    for (int i = 0; i < n; i++) {
        put_str("frame ");
        put_dec(i);
        put_str(" ");
        put_hex(frames[i]);
        put_str(" ");
        put_hex(frames[i] - frame_base[i]);
        put_str(" ");
        put_str(frame_mod[i][0] ? frame_mod[i] : "?");
        put_str("\n");
    }
    put_str("end\n");

    char path[sizeof trace_dir + 40];
    size_t k = 0;
    for (const char *s = trace_dir; *s; s++) path[k++] = *s;
    const char *pre = "/crash-";
    for (const char *s = pre; *s; s++) path[k++] = *s;
    char num[24];
    int m = 0;
    long p = pid;
    do {
        num[m++] = (char)('0' + p % 10);
        p /= 10;
    } while (p);
    while (m) path[k++] = num[--m];
    for (const char *s = ".txt"; *s; s++) path[k++] = *s;
    path[k] = 0;

    long fd = syscall(SYS_openat, AT_FDCWD, path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    for (size_t done = 0; done < out_len;) {
        long w = syscall(SYS_write, fd, out + done, out_len - done);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) break;
        done += (size_t)w;
    }
    syscall(SYS_close, fd);
}

static void on_fatal(int sig, siginfo_t *si, void *uc) {
    int saved = errno;
    if (!atomic_flag_test_and_set(&busy)) write_trace(sig, si, uc);
    /* SA_RESETHAND restored SIG_DFL; the signal is blocked until we return. */
    syscall(SYS_tgkill, syscall(SYS_getpid), syscall(SYS_gettid), sig);
    errno = saved;
}

__attribute__((constructor)) static void crashtrace_init(void) {
    const char *dir = getenv("TORMENT_CRASHTRACE_DIR");
    if (!dir || !*dir || strlen(dir) >= sizeof trace_dir) return;
    memcpy(trace_dir, dir, strlen(dir) + 1);

    void *warm[4];
    backtrace(warm, 4); /* loads libgcc_s now, not in the handler */

    stack_t old;
    if (sigaltstack(NULL, &old) == 0 && (old.ss_flags & SS_DISABLE)) {
        stack_t ss = {.ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0};
        sigaltstack(&ss, NULL);
    }
    for (size_t i = 0; i < sizeof fatal_signals / sizeof fatal_signals[0]; i++) {
        struct sigaction cur;
        if (sigaction(fatal_signals[i], NULL, &cur) != 0) continue;
        if ((cur.sa_flags & SA_SIGINFO) || cur.sa_handler != SIG_DFL) continue;
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = on_fatal;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
        sigemptyset(&sa.sa_mask);
        sigaction(fatal_signals[i], &sa, NULL);
    }
}
