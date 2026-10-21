#!/bin/sh
set -ex

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac
export CFLAGS="$MARCH -O2 -pipe -gno-record-gcc-switches -ffile-prefix-map=$(pwd)=/builddir"
export LDFLAGS="-Wl,--build-id=none"
export CC=gcc

# PREFIX and LIBDIRNAME are compiled into the faketime wrapper, which
# LD_PRELOADs /usr/lib/faketime/libfaketime{,MT}.so.1.
VARS="PREFIX=/usr LIBDIRNAME=/lib/faketime"
make -j$(nproc) $VARS
make install $VARS DESTDIR="$OUTPUT_DIR"
