#!/bin/sh
set -ex

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac
SRC=$(pwd)
REPRO="-pipe -gno-record-gcc-switches -ffile-prefix-map=$SRC=/builddir -ffile-prefix-map=$SRC/asan=/builddir"
LD="-Wl,--build-id=none"

# The Makefile compiles C++ with $(CXX) $(CXXFLAGS) where CXXFLAGS ends in
# $(CFLAGS_PLATFORM) (its own -O2 is clobbered by an empty CDEBUG), builds
# deps/commander/commander.o with make's implicit $(CC) $(CFLAGS) rule, and
# links with LDFLAGS = -lncurses. Our ncurses ships only the wide library, so
# override LDFLAGS on the command line. DATE is pinned for reproducibility.
# Settings and scores go to $HOME/.local/share/nsnake/ (falls back to
# /tmp/.local/share/nsnake/ without $HOME); SYSTEM_LEVEL_DIR is only shown
# in a hint, levels are read from the user dir.
MAKEVARS="DATE=Jan2016 LEVELDIR=/usr/share/games/nsnake/levels"

# ASan+UBSan build in a pristine copy so its objects never mix with release ones.
mkdir asan
cp -a Makefile src deps asan/
(
  cd asan
  SAN="$MARCH $REPRO -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined"
  make -j$(nproc) $MAKEVARS CC=clang CXX=clang++ \
    CFLAGS="$SAN" CFLAGS_PLATFORM="$SAN" \
    LDFLAGS="$LD -fsanitize=address,undefined -lncursesw"
)

REL="$MARCH -O2 $REPRO"
make -j$(nproc) $MAKEVARS CC=gcc CXX=g++ \
  CFLAGS="$REL" CFLAGS_PLATFORM="$REL" LDFLAGS="$LD -lncursesw"

install -Dm755 bin/nsnake "$OUTPUT_DIR/usr/bin/nsnake"
install -Dm755 asan/bin/nsnake "$OUTPUT_DIR/usr/bin/nsnake-asan"
install -dm755 "$OUTPUT_DIR/usr/share/games/nsnake/levels"
install -m644 levels/* "$OUTPUT_DIR/usr/share/games/nsnake/levels/"
install -Dm644 COPYING "$OUTPUT_DIR/usr/share/licenses/nsnake/COPYING"
