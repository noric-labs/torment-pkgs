#!/bin/sh
set -ex

dest="$OUTPUT_DIR/usr/share/zork"
lic="$OUTPUT_DIR/usr/share/licenses/zork-stories"
mkdir -p "$dest" "$lic"

for n in 1 2 3; do
  eval commit=\$MINIMAL_ARG_ZORK${n}_COMMIT
  src="zork$n-$commit"
  install -m 644 "$src/COMPILED/zork$n.z3" "$dest/zork$n.z3"
  install -m 644 "$src/LICENSE" "$lic/LICENSE.zork$n"
done
