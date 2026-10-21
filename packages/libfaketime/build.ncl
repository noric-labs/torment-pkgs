let { Attrs, BuildSpec, Local, OutputBin, OutputData, OutputLib, Source, Test, .. } = import "minimal.ncl" in
let base = import "../base/build.ncl" in
let coreutils = import "../coreutils/build.ncl" in
let glibc = import "../glibc/build.ncl" in
let make = import "../make/build.ncl" in
let toolchain = import "../toolchain/build.ncl" in

let version = "0.9.13" in
{
  name = "libfaketime",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://github.com/wolfcw/libfaketime/archive/refs/tags/v%{version}.tar.gz",
      sha256 = "8e56deeb805682b025107e095f1d94a6ea677472f05824cd475f5c5e6e1a5ddf",
      extract = true,
      strip_prefix = "libfaketime-%{version}",
    } | Source,
    base,
    make,
    toolchain,
  ],
  # The faketime wrapper shells out to `date` to parse non -f timestamps.
  runtime_deps = [
    coreutils,
    glibc,
  ],

  cmd = "./build.sh",

  outputs = {
    bins = { glob = "usr/bin/faketime" } | OutputBin,
    libs = { glob = "usr/lib/faketime/*.so*" } | OutputLib,
    mans = { glob = "usr/share/man/**" } | OutputData,
    docs = { glob = "usr/share/doc/faketime/*" } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "GPL-2.0-only",
      source_provenance = {
        category = 'GithubRepo,
        owner = "wolfcw",
        repo = "libfaketime",
      },
    } | Attrs,

  tests = {
    year_2038 =
      {
        class = 'Standalone,
        test_deps = [base],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -e
          test "$(faketime -f '@2038-01-19 03:14:00' date -u +%Y)" = 2038
          test "$(FAKETIME='@2038-01-19 03:14:00 x60' LD_PRELOAD=/usr/lib/faketime/libfaketime.so.1 date -u +%Y)" = 2038
          test "$(faketime '2038-01-19 03:14:00' date +%Y)" = 2038
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
