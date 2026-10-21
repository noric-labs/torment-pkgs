let { subsetOf, Attrs, BuildSpec, Local, OutputBin, OutputData, Source, Test, .. } = import "minimal.ncl" in
let base = import "../base/build.ncl" in
let gcc = import "../gcc/build.ncl" in
let glibc = import "../glibc/build.ncl" in
let llvm = import "../llvm/build.ncl" in
let make = import "../make/build.ncl" in
let ncurses = import "../ncurses/build.ncl" in
let perl = import "../perl/build.ncl" in
let python = import "../python/build.ncl" in
let tmux = import "../tmux/build.ncl" in
let toolchain = import "../toolchain/build.ncl" in

let version = "0.34.1" in
# PyYAML is only needed at build time, by util/*-gen.py; its pure-python lib
# dir is used straight from the sdist via PYTHONPATH.
let pyyaml_version = "6.0.3" in
{
  name = "dcss",
  build_deps = [
    { file = "build.sh" } | Local,
    # Release tarball (not the git tag archive): carries util/release_ver and
    # the pre-generated levcomp parser, plus bundled lua/sqlite/zlib contribs.
    {
      url = "https://github.com/crawl/crawl/releases/download/%{version}/stone_soup-%{version}.tar.xz",
      sha256 = "473b9cdc16be0b537ac11e43c6c77db4b290000e4a17f72a842eba59c6b7be2a",
      extract = true,
      strip_prefix = "stone_soup-%{version}",
    } | Source,
    {
      url = "https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-%{pyyaml_version}.tar.gz",
      sha256 = "d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f",
    } | Source,
    base,
    llvm,
    make,
    perl,
    python,
    toolchain,
  ],
  runtime_deps = [
    glibc,
    ncurses,
    subsetOf gcc ["libgcc", "libstdcpp"],
  ],

  cmd = "./build.sh",
  build_args = {
    include version,
    include pyyaml_version,
  },

  outputs = {
    crawl = { glob = "usr/bin/crawl" } | OutputBin,
    crawl-asan = { glob = "usr/bin/crawl-asan" } | OutputBin,
    data = { glob = "usr/share/crawl/**" } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "GPL-2.0-or-later",
      source_provenance = {
        category = 'GithubRepo,
        owner = "crawl",
        repo = "crawl",
      },
    } | Attrs,

  tests =
    let screen_test = fun bin =>
      {
        class = 'Standalone,
        test_deps = [base, tmux],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -e
          export HOME=$(mktemp -d) TERM=xterm-256color ASAN_OPTIONS=detect_leaks=0
          tmux -L dcsstest new-session -d -s game -x 80 -y 24 \
            "%{bin} -seed 42 -name tester -species Minotaur -background Fighter -extra-opt-first weapon=trident"
          for i in $(seq 1 60); do
            sleep 1
            screen=$(tmux -L dcsstest capture-pane -p -t game)
            if echo "$screen" | grep -q 'Health:' && echo "$screen" | grep -q 'Game seed: 42'; then
              echo "$screen"
              tmux -L dcsstest kill-server
              echo OK
              exit 0
            fi
          done
          echo "$screen"
          tmux -L dcsstest kill-server || true
          exit 1
        "%
          ],
        ],
      } | Test
    in
    {
      version =
        {
          class = 'Standalone,
          test_deps = [base],
          cmds = [["/bin/bash", "-c", "crawl -version | grep -q 'Crawl version 0.34.1'"]],
        } | Test,
      screen = screen_test "crawl",
      screen_asan = screen_test "crawl-asan",
    },
} | BuildSpec
