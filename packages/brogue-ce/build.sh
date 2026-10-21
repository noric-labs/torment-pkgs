#!/bin/sh
set -ex

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac
SRC=$(pwd)
REPRO="-pipe -gno-record-gcc-switches -ffile-prefix-map=$SRC=/builddir -ffile-prefix-map=$SRC/asan=/builddir"
export LDFLAGS="-Wl,--build-id=none"

# Terminal-only build: no SDL. DATADIR is baked into the binary (used only for
# SDL tiles, which this build omits, and --data-dir). keymap.txt, scores, saves
# and recordings are read/written relative to the cwd.
# The Makefile hardcodes -lncurses; our ncurses ships only the wide library, so
# override `libs` (command-line vars beat the Makefile's := / +=).
MAKEVARS="TERMINAL=YES GRAPHICS=NO RELEASE=YES DATADIR=/usr/share/brogue-ce"
LIBS="-lm -lncursesw"

# ASan+UBSan build in a pristine copy so its objects never mix with release ones.
mkdir asan
cp -a Makefile config.mk make src bin asan/
(
  cd asan
  make -j$(nproc) $MAKEVARS CC=clang libs="$LIBS" \
    CFLAGS="$MARCH $REPRO -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined" \
    LDFLAGS="$LDFLAGS -fsanitize=address,undefined"
)

make -j$(nproc) $MAKEVARS CC=gcc libs="$LIBS" CFLAGS="$MARCH -O2 $REPRO"

install -Dm755 bin/brogue "$OUTPUT_DIR/usr/bin/brogue-ce"
install -Dm755 asan/bin/brogue "$OUTPUT_DIR/usr/bin/brogue-ce-asan"
install -Dm644 bin/keymap.txt "$OUTPUT_DIR/usr/share/brogue-ce/keymap.txt"
cp -r bin/assets "$OUTPUT_DIR/usr/share/brogue-ce/assets"
chmod 644 "$OUTPUT_DIR"/usr/share/brogue-ce/assets/*
install -Dm644 LICENSE.txt "$OUTPUT_DIR/usr/share/licenses/brogue-ce/LICENSE.txt"
