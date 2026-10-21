#!/bin/sh
set -ex

VERSION=$MINIMAL_ARG_VERSION
PYYAML_VERSION=$MINIMAL_ARG_PYYAML_VERSION

# The level/monster/species tables are generated at build time from YAML by
# python scripts that need PyYAML; use its pure-python lib dir from the sdist.
tar -xzf pyyaml-$PYYAML_VERSION.tar.gz
export PYTHONPATH="$(pwd)/pyyaml-$PYYAML_VERSION/lib"

# Two copies of the tree: the release and the sanitizer build differ in
# compiler and flags, and crawl's Makefile caches flags per tree.
cp -a source source-asan

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac

# Console build (no TILES), bundled lua/sqlite/zlib from source/contrib so no
# pkg-config lookup is needed. prefix=/usr gives DATADIR=/usr/share/crawl
# (baked in as an absolute path) and SAVEDIR=~/.crawl (per-user, writable).
COMMON="prefix=/usr bin_prefix=bin NO_PKGCONFIG=y BUILD_LUA=y BUILD_SQLITE=y BUILD_ZLIB=y V=1"
REPRO="-gno-record-gcc-switches -ffile-prefix-map=$(pwd)=/builddir"

# Release build: gcc, -O2 (the Makefile's default CFOPTIMIZE).
# `install` depends on `all` and rebuilds if the flags differ, so pass the
# same flags to both invocations.
REL_FLAGS="$MARCH $REPRO"
REL_LDFLAGS="-Wl,--build-id=none"
make -C source -j$(nproc) $COMMON \
  EXTERNAL_FLAGS="$REL_FLAGS" EXTERNAL_LDFLAGS="$REL_LDFLAGS"
make -C source $COMMON \
  EXTERNAL_FLAGS="$REL_FLAGS" EXTERNAL_LDFLAGS="$REL_LDFLAGS" \
  DESTDIR=$OUTPUT_DIR install

# Sanitizer build: clang ASan+UBSan, -O1 -g, frame pointers.
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer"
make -C source-asan -j$(nproc) $COMMON \
  FORCE_CC=clang FORCE_CXX=clang++ \
  CFOPTIMIZE="-O1" \
  EXTERNAL_FLAGS="$SAN -g $REPRO" \
  EXTERNAL_LDFLAGS="$SAN -Wl,--build-id=none" \
  crawl
install -m 0755 source-asan/crawl $OUTPUT_DIR/usr/bin/crawl-asan

# Desktop/icon files are for the tiles build; drop them.
rm -rf $OUTPUT_DIR/usr/share/applications $OUTPUT_DIR/usr/share/icons $OUTPUT_DIR/usr/share/metainfo
