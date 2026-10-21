#!/bin/sh
set -ex

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac
CFLAGS="$MARCH -O2 -pipe -fPIC -fvisibility=hidden -Wall -Wextra -gno-record-gcc-switches -ffile-prefix-map=$(pwd)=/builddir"
LDFLAGS="-shared -Wl,--build-id=none -Wl,-z,now -Wl,-soname,libtorment_seed.so"

mkdir -p "$OUTPUT_DIR/usr/lib/torment"
gcc $CFLAGS $LDFLAGS -o "$OUTPUT_DIR/usr/lib/torment/libtorment_seed.so" torment_seed.c -ldl

mkdir -p "$OUTPUT_DIR/usr/bin"
gcc $MARCH -O2 -pipe -Wall -Wextra -gno-record-gcc-switches -ffile-prefix-map=$(pwd)=/builddir \
  -Wl,--build-id=none -o "$OUTPUT_DIR/usr/bin/torment-seed-probe" torment_seed_probe.c
