let { upstream, Attrs, BuildSpec, Local, OutputBin, OutputLib, Test, .. } = import "minimal.ncl" in
let base = upstream "base" in
let glibc = upstream "glibc" in
let python = upstream "python" in
let toolchain = upstream "toolchain" in

# LD_PRELOAD shim that makes getrandom, /dev/urandom, rand and arc4random
# deterministic under TORMENT_SEED. Design notes and limits: torment_seed.c.
let lib = "/usr/lib/torment/libtorment_seed.so" in
{
  name = "torment-seed",
  build_deps = [
    { file = "build.sh" } | Local,
    { file = "torment_seed.c" } | Local,
    { file = "torment_seed_probe.c" } | Local,
    base,
    toolchain,
  ],
  runtime_deps = [
    glibc,
  ],

  cmd = "./build.sh",

  outputs = {
    shim = { glob = "usr/lib/torment/libtorment_seed.so" } | OutputLib,
    probe = { glob = "usr/bin/torment-seed-probe" } | OutputBin,
  },

  attrs =
    {
      # Internal package: built from C sources in this directory (MIT).
      license_spdx = "MIT",
    } | Attrs,

  tests = {
    # Same seed twice -> identical; other seed -> different; unset -> passthrough.
    probe_determinism =
      {
        class = 'Standalone,
        test_deps = [base],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -eu
          run() { env LD_PRELOAD=%{lib} "$@" torment-seed-probe; }
          a=$(run TORMENT_SEED=12345); b=$(run TORMENT_SEED=12345); c=$(run TORMENT_SEED=12346)
          [ "$a" = "$b" ]; [ "$a" != "$c" ]
          echo "$a" | grep -q '^child '
          [ "$(echo "$a" | grep '^child ')" != "$(echo "$a" | grep '^parent ')" ]
          u1=$(run); u2=$(run)
          [ "$u1" != "$u2" ]
          [ "$(echo "$u1" | grep '^rand ')" = "$(torment-seed-probe | grep '^rand ')" ]
          echo OK
        "%
          ],
        ],
      } | Test,
    tools_determinism =
      {
        class = 'Standalone,
        test_deps = [base, python],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -eu
          py() { env LD_PRELOAD=%{lib} "$@" python3 -c 'import os;print(os.urandom(8).hex())'; }
          od8() { env LD_PRELOAD=%{lib} "$@" od -An -N8 -tx1 /dev/urandom; }
          [ "$(py TORMENT_SEED=7)" = "$(py TORMENT_SEED=7)" ]
          [ "$(py TORMENT_SEED=7)" != "$(py TORMENT_SEED=8)" ]
          [ "$(py)" != "$(py)" ]
          [ "$(od8 TORMENT_SEED=7)" = "$(od8 TORMENT_SEED=7)" ]
          [ "$(od8 TORMENT_SEED=7)" != "$(od8 TORMENT_SEED=8)" ]
          [ "$(od8)" != "$(od8)" ]
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
