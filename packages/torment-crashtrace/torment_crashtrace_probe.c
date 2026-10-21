/* SPDX-License-Identifier: MIT
 *
 * torment-crashtrace-probe <mode>: dies in a known place, for testing
 * libtorment_crashtrace.so.
 *   segv-a   NULL store in probe_site_a
 *   segv-b   NULL store in probe_site_b (a different stack)
 *   abort    abort() from probe_site_c
 *   fpe      raise(SIGFPE)
 *   own      installs its own SIGSEGV handler, then faults: the handler
 *            prints "own handler" and exits 3 (the library must not interfere)
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile int *volatile null_ptr;

static void __attribute__((noinline)) probe_site_a(int v) { *null_ptr = v; }
static void __attribute__((noinline)) probe_site_b(int v) { null_ptr[1] = v + 1; }
static void __attribute__((noinline)) probe_site_c(void) { abort(); }
static void __attribute__((noinline)) probe_outer(const char *mode) {
    if (!strcmp(mode, "segv-a")) probe_site_a(1);
    else if (!strcmp(mode, "segv-b")) probe_site_b(2);
    else if (!strcmp(mode, "abort")) probe_site_c();
    else if (!strcmp(mode, "fpe")) raise(SIGFPE);
}

static void own_handler(int sig) {
    (void)sig;
    static const char msg[] = "own handler\n";
    write(1, msg, sizeof msg - 1);
    _exit(3);
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "segv-a";
    if (!strcmp(mode, "own")) {
        signal(SIGSEGV, own_handler);
        mode = "segv-a";
    }
    probe_outer(mode);
    fprintf(stderr, "probe: unknown mode %s\n", mode);
    return 2;
}
