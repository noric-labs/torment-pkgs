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

# PREFIX is baked into fiu-run (PLIBPATH) and libfiu.pc (DESTDIR); install
# re-roots PREFIX under $OUTPUT_DIR while keeping the baked paths at /usr.
VARS="DESTDIR=/usr PLIBPATH=/usr/lib"
make -j$(nproc) PREFIX=/usr $VARS
make install PREFIX=$OUTPUT_DIR/usr $VARS
rm -f $OUTPUT_DIR/usr/lib/libfiu.a
