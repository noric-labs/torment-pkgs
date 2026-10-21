#!/bin/sh
set -ex

case $(uname -m) in
  x86_64)  MARCH="-march=x86-64-v3" ;;
  aarch64) MARCH="-march=armv8-a" ;;
  *)       MARCH="" ;;
esac
SRC=$(pwd)
REPRO="-pipe -gno-record-gcc-switches -ffile-prefix-map=$SRC=/builddir -ffile-prefix-map=$SRC/asan=/builddir"

# BastetBlockChooser.hpp includes <boost/tr1/tr1/unordered_set>, which Boost
# removed in 1.65. Shim it with boost::unordered_set (same hashing via
# boost::hash/hash_value as the old TR1 header). CPATH (not -I) so the
# Makefile's own `$(CXX) -MM` dependency step sees it too.
mkdir -p shim/boost/tr1/tr1
cat > shim/boost/tr1/tr1/unordered_set <<'H'
#include <boost/unordered_set.hpp>
namespace std { namespace tr1 { using boost::unordered_set; } }
H
export CPATH="$SRC/shim"

# Upstream links -lncurses; our ncurses only ships the wide-char libncursesw.
mkdir -p curses-shim
echo 'INPUT(-lncursesw)' > curses-shim/libncurses.so

# The Makefile appends with += (to CXXFLAGS/LDFLAGS from the environment), so
# pass flags via the environment, not the make command line. std::bind2nd is
# gone from C++17 on paper; pin gnu++14 rather than rely on libstdc++ keeping it.
BASE_CXXFLAGS="-std=gnu++14 $MARCH $REPRO"
BASE_LDFLAGS="-Wl,--build-id=none -L$SRC/curses-shim"

# High scores: upstream tries /var/games/bastet.scores2 only if it already
# exists and is writable, otherwise it falls back to (and creates)
# $HOME/.bastetscores. On a read-only box root that fallback is always taken,
# so no source change is needed. Keys config: $HOME/.bastetrc.

# ASan+UBSan build in a pristine copy so its objects never mix with release ones.
mkdir asan
cp -a *.cpp *.hpp Makefile asan/
(
  cd asan
  CXXFLAGS="$BASE_CXXFLAGS -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined" \
  LDFLAGS="$BASE_LDFLAGS -fsanitize=address,undefined" \
    make -j$(nproc) CXX=clang++ bastet
)

CXXFLAGS="$BASE_CXXFLAGS -O2" LDFLAGS="$BASE_LDFLAGS" make -j$(nproc) CXX=g++ bastet

install -Dm755 bastet "$OUTPUT_DIR/usr/bin/bastet"
install -Dm755 asan/bastet "$OUTPUT_DIR/usr/bin/bastet-asan"
install -Dm644 LICENSE "$OUTPUT_DIR/usr/share/licenses/bastet/LICENSE"
