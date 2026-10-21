let { upstream, Attrs, BuildSpec, Local, OutputBin, OutputData, Source, Test, .. } = import "minimal.ncl" in
let base = upstream "base" in
let glibc = upstream "glibc" in
let make = upstream "make" in
let ncurses = upstream "ncurses" in
let toolchain = upstream "toolchain" in
let zork-stories = import "../zork-stories/build.ncl" in

let version = "2.55" in
{
  name = "frotz",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      # Release tarball linked from the GitLab release page
      # (https://gitlab.com/DavidGriffith/frotz/-/releases/2.55).
      url = "https://ifarchive.org/if-archive/infocom/interpreters/frotz/frotz-%{version}.tar.gz",
      sha256 = "e3d6912ff94bca724759fe59aa222c1ee23aa4d35ffa15a0b40f72f97887d871",
      extract = true,
      strip_prefix = "frotz-%{version}",
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
    # dfrotz: dumb-terminal interface (stdin/stdout); frotz: curses interface.
    # Both take `-s N` to fix the RNG seed (N is parsed with atoi; 0 or
    # absent means seed from the clock).
    bins = { glob = "usr/bin/{dfrotz,frotz}" } | OutputBin,
    mans = { glob = "usr/share/man/man6/*frotz.6" } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "GPL-2.0-or-later",
    } | Attrs,

  tests = {
    zork1_seeded =
      {
        class = 'Standalone,
        test_deps = [base, zork-stories],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -e
          run() { printf 'look\nquit\ny\n' | dfrotz -s 42 -m /usr/share/zork/zork1.z3; }
          a=$(run); b=$(run)
          grep -q 'West of House' <<<"$a"
          [ "$a" = "$b" ]
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
