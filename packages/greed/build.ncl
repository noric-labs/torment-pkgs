let { upstream, Attrs, BuildSpec, Local, OutputBin, Source, Test, .. } = import "minimal.ncl" in
let base = upstream "base" in
let glibc = upstream "glibc" in
let make = upstream "make" in
let ncurses = upstream "ncurses" in
let toolchain = upstream "toolchain" in
let util-linux = upstream "util-linux" in

# 4.5 is the last C/ncurses release; 5.x is a Rust/crossterm rewrite.
let version = "4.5" in
{
  name = "greed",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://gitlab.com/esr/greed/-/archive/%{version}/greed-%{version}.tar.gz",
      sha256 = "c38643784b68f4a889c734c9d2f76f64378ba1089559d24136665bbb05f9dfda",
      extract = true,
      strip_prefix = "greed-%{version}",
    } | Source,
    base,
    make,
    toolchain,
  ],
  runtime_deps = [
    glibc,
    ncurses,
  ],

  cmd = "./build.sh",

  outputs = {
    greed = { glob = "usr/bin/greed" } | OutputBin,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "BSD-2-Clause",
    } | Attrs,

  tests = {
    draws_in_pty =
      {
        class = 'Standalone,
        test_deps = [base, util-linux],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -e
          export TERM=xterm-256color
          out=$( (sleep 1; printf q; sleep 1; printf y; sleep 1) | timeout 10 script -qec "greed -r42" /dev/null)
          echo "$out" | grep -q "Greed v4.5"
          echo "$out" | grep -q "Really quit"
          test -w /tmp/greed.hs || test -w "$HOME/.greedscores"
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
