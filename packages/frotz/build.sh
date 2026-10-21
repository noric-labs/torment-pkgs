#!/bin/sh
set -ex

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac
export CFLAGS="$MARCH -O2 -pipe -gno-record-gcc-switches -ffile-prefix-map=$(pwd)=/builddir"
export LDFLAGS="-Wl,--build-id=none"

# The Makefile probes for pkgconf and ranlib via `which`, which the build
# sandbox lacks; set both explicitly. NO_PKGCONF=yes links plain -lncursesw
# (headers live in /usr/include).
# SOUND_TYPE=none: no libao, so the curses build is silent.
MAKEVARS="PREFIX=/usr CC=gcc AR=ar RANLIB=ranlib NO_PKGCONF=yes CURSES=ncursesw SOUND_TYPE=none"

make -j$(nproc) $MAKEVARS frotz dfrotz
make $MAKEVARS DESTDIR="$OUTPUT_DIR" install_frotz install_dfrotz
