/* SPDX-License-Identifier: MIT
 *
 * libtorment_seed.so: an LD_PRELOAD shim that makes a process's randomness
 * deterministic when TORMENT_SEED=<u64> is set. With TORMENT_SEED unset,
 * every hook forwards to the next definition (libc) untouched.
 *
 * Covered (dynamic glibc programs, calls made through the PLT):
 *   getrandom, getentropy, syscall(SYS_getrandom, ...)
 *   arc4random, arc4random_buf, arc4random_uniform
 *   reads of /dev/urandom and /dev/random (any path that resolves to char
 *     device 1:8 or 1:9), via open/openat/fopen + read/readv/pread, and fds
 *     inherited from the parent (e.g. `prog < /dev/urandom`)
 *   rand, random, srand, srandom, rand_r, initstate, srand48
 *
 * Design
 *   PRNG: xoshiro256** seeded with splitmix64. One "byte stream" serves
 *   getrandom/getentropy/arc4random/device reads; a separate "rand stream"
 *   serves rand()/random() so srand() can reset it without disturbing the rest.
 *
 *   /dev/urandom: we keep the real device fd (so fstat, poll, fcntl and
 *   close behave normally) and interpose the read family. open*() results are
 *   classified by fstat (st_rdev 1:8/1:9), not by path, and marked in a fd
 *   table; dup/dup2/dup3/fcntl(F_DUPFD*) propagate the mark, close clears it.
 *   Before serving a marked fd the read re-checks fstat, so a stale mark (fd
 *   closed by a path we do not see) degrades to a plain pass-through read.
 *   fopen() of the device returns an fopencookie() stream, because glibc stdio
 *   reads through internal, non-interposable calls (fileno() of that FILE is -1).
 *   No pipe/memfd: they are finite or need a writer, and fstat would lie.
 *
 *   srand/srandom: by default the argument is ignored and the rand stream is
 *   reset to its seed-derived start, so srand(time(NULL)) or srand(getpid())
 *   stays reproducible. TORMENT_SEED_SRAND=mix mixes the argument in instead,
 *   for programs that rely on srand(k) to regenerate content.
 *
 *   fork: the child does NOT replay the parent's stream. At fork the parent
 *   draws one u64 k; the child reseeds as stream k and writes k into
 *   TORMENT_SEED_STREAM (in place in environ, no allocation) so a later exec
 *   continues from that lineage. execve() is also hooked to put the current
 *   stream into an explicit envp (shells such as bash build their own envp). A process tree is therefore reproducible as long as
 *   its fork order is. A freshly exec'd process with no TORMENT_SEED_STREAM
 *   uses stream 0; we export a 16-hex-digit placeholder at startup so the
 *   in-place rewrite has room.
 *
 * Limits: static binaries and raw syscalls (Go, inline svc/syscall) bypass
 * the shim; glibc-internal randomness (AT_RANDOM stack canary/pointer guard,
 * mkstemp/tmpnam name generation via __getrandom_nocancel, malloc) and ASLR
 * are not affected; stdio reading an inherited device fd (fread(stdin) when
 * stdin is /dev/urandom) is not covered; CPU instructions (rdrand/rndr)
 * are untouched. Time is left to libfaketime.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <pthread.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

/* ---------- PRNG ---------- */

static uint64_t splitmix64(uint64_t *x) {
    uint64_t z = (*x += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

typedef struct { uint64_t s[4]; } xoshiro;

static inline uint64_t rotl(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }

static uint64_t xo_next(xoshiro *r) {
    uint64_t *s = r->s;
    uint64_t result = rotl(s[1] * 5, 7) * 9;
    uint64_t t = s[1] << 17;
    s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3];
    s[2] ^= t; s[3] = rotl(s[3], 45);
    return result;
}

static void xo_seed(xoshiro *r, uint64_t a, uint64_t b, uint64_t domain) {
    uint64_t x = a ^ splitmix64(&b) ^ (domain * 0xd1b54a32d192ed03ULL);
    for (int i = 0; i < 4; i++) r->s[i] = splitmix64(&x);
}

/* ---------- state ---------- */

enum { D_BYTES = 1, D_RAND = 2, D_FORK = 3 };

static int g_init;            /* 0 = not yet, 1 = done */
static int g_enabled;
static int g_srand_mix;
static uint64_t g_seed, g_stream;
static xoshiro g_bytes, g_rand;
static volatile int g_lock;
static char *g_stream_env;    /* points at the 16 hex digits in environ */

#define MAXFD 65536
static unsigned char g_rndfd[MAXFD];

static void lock(void) { while (__atomic_test_and_set(&g_lock, __ATOMIC_ACQUIRE)) ; }
static void unlock(void) { __atomic_clear(&g_lock, __ATOMIC_RELEASE); }

static uint64_t parse_u64(const char *s) {
    char *end;
    errno = 0;
    unsigned long long v = strtoull(s, &end, (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) ? 16 : 10);
    if (*s && !*end && !errno) return v;
    uint64_t h = 0xcbf29ce484222325ULL;          /* not a number: FNV-1a */
    for (; *s; s++) h = (h ^ (unsigned char)*s) * 0x100000001b3ULL;
    return h;
}

static void reseed_all(void) {
    xo_seed(&g_bytes, g_seed, g_stream, D_BYTES);
    xo_seed(&g_rand, g_seed, g_stream, D_RAND);
}

static void init(void) {
    if (__atomic_load_n(&g_init, __ATOMIC_ACQUIRE)) return;
    lock();
    if (!g_init) {
        const char *s = getenv("TORMENT_SEED");
        if (s && *s) {
            g_enabled = 1;
            g_seed = parse_u64(s);
            const char *st = getenv("TORMENT_SEED_STREAM");
            g_stream = (st && *st) ? strtoull(st, NULL, 16) : 0;
            const char *m = getenv("TORMENT_SEED_SRAND");
            g_srand_mix = m && strcmp(m, "mix") == 0;
            reseed_all();
        }
        __atomic_store_n(&g_init, 1, __ATOMIC_RELEASE);
    }
    unlock();
}

static void fill_locked(xoshiro *r, void *buf, size_t n) {
    unsigned char *p = buf;
    while (n >= 8) { uint64_t v = xo_next(r); memcpy(p, &v, 8); p += 8; n -= 8; }
    if (n) { uint64_t v = xo_next(r); memcpy(p, &v, n); }
}

static void fill(void *buf, size_t n) { lock(); fill_locked(&g_bytes, buf, n); unlock(); }
static uint64_t next_bytes(void) { lock(); uint64_t v = xo_next(&g_bytes); unlock(); return v; }

/* ---------- real symbols ---------- */

#define REAL(ret, name, ...) \
    static ret (*real_##name)(__VA_ARGS__); \
    static ret (*get_##name(void))(__VA_ARGS__) { \
        if (!real_##name) real_##name = dlsym(RTLD_NEXT, #name); \
        return real_##name; }

REAL(ssize_t, getrandom, void *, size_t, unsigned)
REAL(int, getentropy, void *, size_t)
REAL(long, syscall, long, long, long, long, long, long, long)
REAL(uint32_t, arc4random, void)
REAL(void, arc4random_buf, void *, size_t)
REAL(uint32_t, arc4random_uniform, uint32_t)
REAL(int, rand, void)
REAL(void, srand, unsigned)
REAL(long, random, void)
REAL(void, srandom, unsigned)
REAL(int, rand_r, unsigned *)
REAL(char *, initstate, unsigned, char *, size_t)
REAL(void, srand48, long)
REAL(int, open, const char *, int, ...)
REAL(int, open64, const char *, int, ...)
REAL(int, openat, int, const char *, int, ...)
REAL(int, openat64, int, const char *, int, ...)
REAL(int, __open_2, const char *, int)
REAL(int, __open64_2, const char *, int)
REAL(int, __openat_2, int, const char *, int)
REAL(int, __openat64_2, int, const char *, int)
REAL(FILE *, fopen, const char *, const char *)
REAL(FILE *, fopen64, const char *, const char *)
REAL(ssize_t, read, int, void *, size_t)
REAL(ssize_t, __read_chk, int, void *, size_t, size_t)
REAL(ssize_t, pread, int, void *, size_t, off_t)
REAL(ssize_t, pread64, int, void *, size_t, off_t)
REAL(ssize_t, __pread_chk, int, void *, size_t, off_t, size_t)
REAL(ssize_t, __pread64_chk, int, void *, size_t, off_t, size_t)
REAL(ssize_t, readv, int, const struct iovec *, int)
REAL(int, close, int)
REAL(int, dup, int)
REAL(int, dup2, int, int)
REAL(int, dup3, int, int, int)
REAL(int, fcntl, int, int, ...)
REAL(int, fcntl64, int, int, ...)
REAL(int, execve, const char *, char *const[], char *const[])

/* ---------- device fd tracking ---------- */

static int is_rnd_dev(int fd) {
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || !S_ISCHR(st.st_mode)) return 0;
    return major(st.st_rdev) == 1 && (minor(st.st_rdev) == 8 || minor(st.st_rdev) == 9);
}

static int classify(int fd) {          /* after open: mark if it is the device */
    if (fd >= 0 && fd < MAXFD && g_enabled) g_rndfd[fd] = (unsigned char)is_rnd_dev(fd);
    return fd;
}

static int serve(int fd) {             /* should this read be served by us? */
    if (!g_enabled || fd < 0 || fd >= MAXFD || !g_rndfd[fd]) return 0;
    if (is_rnd_dev(fd)) return 1;
    g_rndfd[fd] = 0;
    return 0;
}

static void copy_mark(int from, int to) {
    if (!g_enabled || to < 0 || to >= MAXFD) return;
    g_rndfd[to] = (from >= 0 && from < MAXFD) ? g_rndfd[from] : 0;
}

/* ---------- fork & startup ---------- */

static void hexput(char *dst, uint64_t v) {
    static const char hx[] = "0123456789abcdef";
    for (int i = 15; i >= 0; i--) { dst[i] = hx[v & 15]; v >>= 4; }
}

static uint64_t g_fork_k;
static void at_prepare(void) {
    if (!g_enabled) return;
    lock();
    g_fork_k = splitmix64(&(uint64_t){ xo_next(&g_bytes) ^ D_FORK });
}
static void at_parent(void) { if (g_enabled) unlock(); }
static void at_child(void) {
    if (!g_enabled) return;
    g_stream = g_fork_k;
    reseed_all();
    if (g_stream_env) hexput(g_stream_env, g_stream);
    g_lock = 0;
}

__attribute__((constructor)) static void ts_ctor(void) {
    init();
    if (!g_enabled) return;
    char *v = getenv("TORMENT_SEED_STREAM");
    if (!v || strlen(v) != 16) {
        char buf[17];
        hexput(buf, g_stream);
        buf[16] = 0;
        setenv("TORMENT_SEED_STREAM", buf, 1);
        v = getenv("TORMENT_SEED_STREAM");
    }
    if (v && strlen(v) == 16) g_stream_env = v;
    pthread_atfork(at_prepare, at_parent, at_child);
    for (int fd = 0; fd < 64; fd++) classify(fd);   /* inherited device fds */
}

/* ---------- getrandom family ---------- */

EXPORT ssize_t getrandom(void *buf, size_t n, unsigned flags) {
    init();
    if (!g_enabled) return get_getrandom()(buf, n, flags);
    if (flags & ~(GRND_NONBLOCK | GRND_RANDOM | 0x0004 /* GRND_INSECURE */)) { errno = EINVAL; return -1; }
    if (n > 33554431) n = 33554431;   /* kernel caps a single call at 32 MiB - 1 */
    fill(buf, n);
    return (ssize_t)n;
}

EXPORT int getentropy(void *buf, size_t n) {
    init();
    if (!g_enabled) return get_getentropy()(buf, n);
    if (n > 256) { errno = EIO; return -1; }
    fill(buf, n);
    return 0;
}

EXPORT long syscall(long nr, ...) {
    va_list ap;
    va_start(ap, nr);
    long a = va_arg(ap, long), b = va_arg(ap, long), c = va_arg(ap, long);
    long d = va_arg(ap, long), e = va_arg(ap, long), f = va_arg(ap, long);
    va_end(ap);
    init();
    if (g_enabled && nr == SYS_getrandom) return getrandom((void *)a, (size_t)b, (unsigned)c);
    return get_syscall()(nr, a, b, c, d, e, f);
}

EXPORT uint32_t arc4random(void) {
    init();
    if (!g_enabled) return get_arc4random()();
    return (uint32_t)(next_bytes() >> 32);
}

EXPORT void arc4random_buf(void *buf, size_t n) {
    init();
    if (!g_enabled) { get_arc4random_buf()(buf, n); return; }
    fill(buf, n);
}

EXPORT uint32_t arc4random_uniform(uint32_t bound) {
    init();
    if (!g_enabled) return get_arc4random_uniform()(bound);
    if (bound < 2) return 0;
    uint32_t min = -bound % bound;    /* reject to avoid modulo bias */
    for (;;) { uint32_t r = (uint32_t)(next_bytes() >> 32); if (r >= min) return r % bound; }
}

/* ---------- rand family ---------- */

static void rand_reset(unsigned arg) {
    lock();
    xo_seed(&g_rand, g_seed, g_stream ^ (g_srand_mix ? ((uint64_t)arg << 1 | 1) : 0), D_RAND);
    unlock();
}

static long rand31(void) { lock(); uint64_t v = xo_next(&g_rand); unlock(); return (long)(v >> 33); }

EXPORT int rand(void) { init(); return g_enabled ? (int)rand31() : get_rand()(); }
EXPORT long random(void) { init(); return g_enabled ? rand31() : get_random()(); }
EXPORT void srand(unsigned s) { init(); if (g_enabled) rand_reset(s); else get_srand()(s); }
EXPORT void srandom(unsigned s) { init(); if (g_enabled) rand_reset(s); else get_srandom()(s); }

EXPORT int rand_r(unsigned *seedp) {
    init();
    if (!g_enabled) return get_rand_r()(seedp);
    /* stateless in *seedp, like glibc: same *seedp gives the same output */
    uint64_t x = g_seed ^ ((uint64_t)*seedp * 0x9e3779b97f4a7c15ULL);
    uint64_t v = splitmix64(&x);
    *seedp = (unsigned)(v >> 32);
    return (int)(v >> 33);
}

EXPORT char *initstate(unsigned s, char *state, size_t n) {
    init();
    char *old = get_initstate()(s, state, n);
    if (g_enabled) rand_reset(s);
    return old;
}

EXPORT void srand48(long s) {
    init();
    if (g_enabled) {
        uint64_t x = g_seed ^ g_stream ^ (g_srand_mix ? (uint64_t)s : 0);
        s = (long)splitmix64(&x);
    }
    get_srand48()(s);
}

/* ---------- open / fopen ---------- */

static int needs_mode(int flags) { return (flags & O_CREAT) || (flags & __O_TMPFILE) == __O_TMPFILE; }

#define OPEN_HOOK(name)                                                   \
    EXPORT int name(const char *p, int flags, ...) {                      \
        mode_t m = 0;                                                     \
        if (needs_mode(flags)) { va_list ap; va_start(ap, flags);         \
            m = va_arg(ap, mode_t); va_end(ap); }                         \
        init();                                                           \
        return classify(get_##name()(p, flags, m));                       \
    }
OPEN_HOOK(open)
OPEN_HOOK(open64)

#define OPENAT_HOOK(name)                                                 \
    EXPORT int name(int dfd, const char *p, int flags, ...) {             \
        mode_t m = 0;                                                     \
        if (needs_mode(flags)) { va_list ap; va_start(ap, flags);         \
            m = va_arg(ap, mode_t); va_end(ap); }                         \
        init();                                                           \
        return classify(get_##name()(dfd, p, flags, m));                  \
    }
OPENAT_HOOK(openat)
OPENAT_HOOK(openat64)

EXPORT int __open_2(const char *p, int f) { init(); return classify(get___open_2()(p, f)); }
EXPORT int __open64_2(const char *p, int f) { init(); return classify(get___open64_2()(p, f)); }
EXPORT int __openat_2(int d, const char *p, int f) { init(); return classify(get___openat_2()(d, p, f)); }
EXPORT int __openat64_2(int d, const char *p, int f) { init(); return classify(get___openat64_2()(d, p, f)); }

static ssize_t ck_read(void *c, char *buf, size_t n) { (void)c; fill(buf, n); return (ssize_t)n; }
static ssize_t ck_write(void *c, const char *buf, size_t n) {
    return write((int)(intptr_t)c, buf, n);     /* entropy feed: pass to the device */
}
static int ck_close(void *c) { return get_close()((int)(intptr_t)c); }

static FILE *wrap_fopen(FILE *f, const char *mode) {
    if (!f || !g_enabled) return f;
    int fd = fileno(f);
    if (!is_rnd_dev(fd)) return f;
    int nfd = get_fcntl()(fd, F_DUPFD_CLOEXEC, 3);
    if (nfd < 0) return f;
    cookie_io_functions_t io = { .read = ck_read, .write = ck_write, .seek = NULL, .close = ck_close };
    FILE *c = fopencookie((void *)(intptr_t)nfd, mode, io);
    if (!c) { get_close()(nfd); return f; }
    fclose(f);
    return c;
}

EXPORT FILE *fopen(const char *p, const char *m) { init(); return wrap_fopen(get_fopen()(p, m), m); }
EXPORT FILE *fopen64(const char *p, const char *m) { init(); return wrap_fopen(get_fopen64()(p, m), m); }

/* ---------- read family ---------- */

EXPORT ssize_t read(int fd, void *buf, size_t n) {
    if (serve(fd)) { fill(buf, n); return (ssize_t)n; }
    return get_read()(fd, buf, n);
}
EXPORT ssize_t __read_chk(int fd, void *buf, size_t n, size_t bl) {
    if (n > bl) return get___read_chk()(fd, buf, n, bl);   /* let glibc abort */
    if (serve(fd)) { fill(buf, n); return (ssize_t)n; }
    return get___read_chk()(fd, buf, n, bl);
}
EXPORT ssize_t pread(int fd, void *buf, size_t n, off_t o) {
    if (serve(fd)) { fill(buf, n); return (ssize_t)n; }
    return get_pread()(fd, buf, n, o);
}
EXPORT ssize_t pread64(int fd, void *buf, size_t n, off_t o) {
    if (serve(fd)) { fill(buf, n); return (ssize_t)n; }
    return get_pread64()(fd, buf, n, o);
}
EXPORT ssize_t __pread_chk(int fd, void *buf, size_t n, off_t o, size_t bl) {
    if (n <= bl && serve(fd)) { fill(buf, n); return (ssize_t)n; }
    return get___pread_chk()(fd, buf, n, o, bl);
}
EXPORT ssize_t __pread64_chk(int fd, void *buf, size_t n, off_t o, size_t bl) {
    if (n <= bl && serve(fd)) { fill(buf, n); return (ssize_t)n; }
    return get___pread64_chk()(fd, buf, n, o, bl);
}
EXPORT ssize_t readv(int fd, const struct iovec *iov, int cnt) {
    if (serve(fd) && cnt >= 0) {
        ssize_t t = 0;
        lock();
        for (int i = 0; i < cnt; i++) { fill_locked(&g_bytes, iov[i].iov_base, iov[i].iov_len); t += (ssize_t)iov[i].iov_len; }
        unlock();
        return t;
    }
    return get_readv()(fd, iov, cnt);
}

/* ---------- fd lifetime ---------- */

EXPORT int close(int fd) {
    if (fd >= 0 && fd < MAXFD) g_rndfd[fd] = 0;
    return get_close()(fd);
}
EXPORT int dup(int fd) { int r = get_dup()(fd); if (r >= 0) copy_mark(fd, r); return r; }
EXPORT int dup2(int fd, int nfd) { int r = get_dup2()(fd, nfd); if (r >= 0) copy_mark(fd, r); return r; }
EXPORT int dup3(int fd, int nfd, int fl) { int r = get_dup3()(fd, nfd, fl); if (r >= 0) copy_mark(fd, r); return r; }

#define FCNTL_HOOK(name)                                                  \
    EXPORT int name(int fd, int cmd, ...) {                               \
        va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap); \
        int r = get_##name()(fd, cmd, arg);                               \
        if (r >= 0 && (cmd == F_DUPFD || cmd == F_DUPFD_CLOEXEC)) copy_mark(fd, r); \
        return r;                                                         \
    }
FCNTL_HOOK(fcntl)
FCNTL_HOOK(fcntl64)

/* ---------- exec: carry the stream id into the new image ---------- */

EXPORT int execve(const char *path, char *const argv[], char *const envp[]) {
    if (!g_enabled || !envp) return get_execve()(path, argv, envp);
    static const char key[] = "TORMENT_SEED_STREAM=";
    size_t n = 0;
    while (envp[n]) n++;
    char *nenv[n + 2];
    char ent[sizeof key + 16];
    size_t j = 0;
    for (size_t i = 0; i < n; i++)
        if (strncmp(envp[i], key, sizeof key - 1) != 0) nenv[j++] = envp[i];
    memcpy(ent, key, sizeof key - 1);
    hexput(ent + sizeof key - 1, g_stream);
    ent[sizeof key - 1 + 16] = 0;
    nenv[j++] = ent;
    nenv[j] = NULL;
    return get_execve()(path, argv, nenv);
}
