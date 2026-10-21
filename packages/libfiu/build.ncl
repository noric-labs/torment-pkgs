let { Attrs, BuildSpec, Local, OutputBin, OutputData, OutputLib, Source, Test, .. } = import "minimal.ncl" in
let base = import "../base/build.ncl" in
let bash = import "../bash/build.ncl" in
let glibc = import "../glibc/build.ncl" in
let make = import "../make/build.ncl" in
let toolchain = import "../toolchain/build.ncl" in

let version = "1.2" in
{
  name = "libfiu",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://blitiri.com.ar/p/libfiu/files/%{version}/libfiu-%{version}.tar.gz",
      sha256 = "353ab3b50709cdd91522d7e4bb7ff800b27a97f72b989e22ce426c6de2669674",
      extract = true,
      strip_prefix = "libfiu-%{version}",
    } | Source,
    base,
    make,
    toolchain,
  ],
  runtime_deps = [
    bash,
    glibc,
  ],

  cmd = "./build.sh",

  outputs = {
    bins = { glob = "usr/bin/fiu-*" } | OutputBin,
    libs = { glob = "usr/lib/*.so*" } | OutputLib,
    includes = { glob = "usr/include/**" } | OutputData,
    pkgconfig = { glob = "usr/lib/pkgconfig/libfiu.pc" } | OutputData,
    mans = { glob = "usr/share/man/**" } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "LicenseRef-BOLA-1.1",
      source_provenance = {
        category = 'GithubRepo,
        owner = "albertito",
        repo = "libfiu",
      },
    } | Attrs,

  tests = {
    malloc_fault =
      {
        class = 'Standalone,
        test_deps = [base],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          fiu-run -x -c 'enable name=posix/io/oc/open' cat /etc/hostname && exit 1
          fiu-run -x -c 'enable name=libc/mm/malloc' true || true
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
