let { upstream, subsetOf, Attrs, BuildSpec, Local, OutputBin, OutputLib, Test, .. } = import "minimal.ncl" in
let base = upstream "base" in
let gcc = upstream "gcc" in
let glibc = upstream "glibc" in
let toolchain = upstream "toolchain" in

# LD_PRELOAD library that writes the faulting stack (pc + module-relative
# offsets) to $TORMENT_CRASHTRACE_DIR/crash-<pid>.txt on SIGSEGV, SIGBUS,
# SIGFPE, SIGILL and SIGABRT, then dies from the same signal. The harness
# symbolizes it into a stack_hash. Design notes and limits: torment_crashtrace.c.
let lib = "/usr/lib/torment/libtorment_crashtrace.so" in
{
  name = "torment-crashtrace",
  build_deps = [
    { file = "build.sh" } | Local,
    { file = "torment_crashtrace.c" } | Local,
    { file = "torment_crashtrace_probe.c" } | Local,
    base,
    toolchain,
  ],
  runtime_deps = [
    glibc,
    # backtrace() loads libgcc_s for the unwinder.
    subsetOf gcc ["libgcc"],
  ],

  cmd = "./build.sh",

  outputs = {
    lib = { glob = "usr/lib/torment/libtorment_crashtrace.so" } | OutputLib,
    probe = { glob = "usr/bin/torment-crashtrace-probe" } | OutputBin,
  },

  attrs =
    {
      # Internal package: built from C sources in this directory (MIT).
      license_spdx = "MIT",
    } | Attrs,

  tests = {
    # Each crash writes a trace and still dies from its own signal; distinct
    # sites give distinct frame-0 offsets, the same site the same offsets;
    # a program's own SIGSEGV handler is left alone; unset -> no trace.
    probe_traces =
      {
        class = 'Standalone,
        test_deps = [base],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -eu
          d=$(mktemp -d)
          run() { local rc=0; env LD_PRELOAD=%{lib} TORMENT_CRASHTRACE_DIR="$d/$1" torment-crashtrace-probe "$2" || rc=$?; echo $rc; }
          offs() { sed -n 's/^frame [0-9]* 0x[0-9a-f]* \(0x[0-9a-f]*\) .*probe$/\1/p' "$d/$1"/crash-*.txt | tr '\n' ' '; }
          mkdir -p "$d"/a1 "$d"/a2 "$d"/b "$d"/ab "$d"/own
          [ "$(run a1 segv-a)" = 139 ]; [ "$(run a2 segv-a)" = 139 ]; [ "$(run b segv-b)" = 139 ]
          [ "$(run ab abort)" = 134 ]
          for x in a1 a2 b ab; do grep -q '^end$' "$d/$x"/crash-*.txt; grep -q '^unwound 1$' "$d/$x"/crash-*.txt; done
          grep -q '^signal 11$' "$d"/a1/crash-*.txt; grep -q '^signal 6$' "$d"/ab/crash-*.txt
          [ -n "$(offs a1)" ]; [ "$(offs a1)" = "$(offs a2)" ]; [ "$(offs a1)" != "$(offs b)" ]
          [ "$(env LD_PRELOAD=%{lib} TORMENT_CRASHTRACE_DIR="$d/own" torment-crashtrace-probe own)" = "own handler" ]
          [ -z "$(ls "$d/own")" ]
          rc=0; env LD_PRELOAD=%{lib} torment-crashtrace-probe segv-a || rc=$?; [ $rc = 139 ]
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
