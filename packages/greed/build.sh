#!/bin/sh
set -ex

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac
export CFLAGS="$MARCH -O2 -pipe -gno-record-gcc-switches -ffile-prefix-map=$(pwd)=/builddir"
# greed.c uses K&R-style `void (*)()` signal handlers, which GCC 15's
# default C23 rejects.
CFLAGS="$CFLAGS -std=gnu17"
export CC=gcc

# Upstream links with -lcurses; our ncurses only ships the wide-char
# libncursesw, so point -lcurses at it with a linker script.
mkdir -p curses-shim
echo 'INPUT(-lncursesw)' > curses-shim/libcurses.so
export LDFLAGS="-Wl,--build-id=none -L$(pwd)/curses-shim"

# The default score file (/usr/games/lib/greed.hs) is not writable by an
# unprivileged user. /tmp/greed.hs is: the first player creates it 0600, and
# anyone else falls back to upstream's ~/.greedscores.
make greed SFILE=/tmp/greed.hs

# Only the binary: the man page needs asciidoctor, which we don't ship.
install -Dm0755 greed "$OUTPUT_DIR/usr/bin/greed"
