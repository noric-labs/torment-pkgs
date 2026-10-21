/* SPDX-License-Identifier: MIT
 * torment-seed-probe: print a sample of every randomness source the
 * libtorment_seed.so shim covers, one per line, for determinism checks. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static void hex(const char *tag, const unsigned char *b, size_t n) {
    printf("%-10s ", tag);
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

int main(void) {
    unsigned char b[8];
    if (getrandom(b, sizeof b, 0) != (ssize_t)sizeof b) return 1;
    hex("getrandom", b, sizeof b);
    if (getentropy(b, sizeof b)) return 1;
    hex("getentropy", b, sizeof b);
    if (syscall(SYS_getrandom, b, sizeof b, 0) != (long)sizeof b) return 1;
    hex("syscall", b, sizeof b);
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0 || read(fd, b, sizeof b) != (ssize_t)sizeof b) return 1;
    close(fd);
    hex("urandom", b, sizeof b);
    FILE *f = fopen("/dev/random", "rb");
    if (!f || fread(b, 1, sizeof b, f) != sizeof b) return 1;
    fclose(f);
    hex("fopen", b, sizeof b);
    arc4random_buf(b, sizeof b);
    hex("arc4", b, sizeof b);
    printf("%-10s %u\n", "arc4u", arc4random_uniform(1000000));
    srand(42);
    int r1 = rand(), r2 = rand();
    printf("%-10s %d %d\n", "rand", r1, r2);
    srandom(7);
    printf("%-10s %ld\n", "random", random());
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        getrandom(b, sizeof b, 0);
        hex("child", b, sizeof b);
        fflush(stdout);
        _exit(0);
    }
    waitpid(pid, NULL, 0);
    getrandom(b, sizeof b, 0);
    hex("parent", b, sizeof b);
    return 0;
}
