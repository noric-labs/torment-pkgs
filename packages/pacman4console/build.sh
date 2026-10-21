#!/bin/sh
set -ex

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac
SRC=$(pwd)
REPRO="-pipe -gno-record-gcc-switches -ffile-prefix-map=$SRC=/builddir"
export LDFLAGS="-Wl,--build-id=none"

# The orig tarball ships prebuilt Mach-O binaries (pacman, pacmanedit); never
# use them. The Makefile hardcodes gcc and -lncurses (our ncurses only ships
# the wide library), so compile pacman.c directly.
#
# pacman.h builds the level path as DATAROOTDIR "/pacman/Levels/level0N.dat".
# Setting DATAROOTDIR (no source patch) puts the levels at
# /usr/share/pacman4console/pacman/Levels/.
# The source builds cleanly under GCC 15's C23 default; ftime() is only
# deprecated, not removed, so silence that warning.
DEFS="-DDATAROOTDIR=\"/usr/share/pacman4console\" -Wno-deprecated-declarations"
LIBS="-lncursesw"

gcc $MARCH -O2 $REPRO $DEFS pacman.c -o pacman4console $LDFLAGS $LIBS

clang $MARCH $REPRO -g -O1 -fno-omit-frame-pointer \
  -fsanitize=address,undefined -fno-sanitize-recover=undefined \
  $DEFS pacman.c -o pacman4console-asan $LDFLAGS -fsanitize=address,undefined $LIBS

install -Dm755 pacman4console "$OUTPUT_DIR/usr/bin/pacman4console"
install -Dm755 pacman4console-asan "$OUTPUT_DIR/usr/bin/pacman4console-asan"
for f in Levels/level0[1-9].dat; do
  install -Dm644 "$f" "$OUTPUT_DIR/usr/share/pacman4console/pacman/$f"
done
install -Dm644 COPYING "$OUTPUT_DIR/usr/share/licenses/pacman4console/COPYING"
