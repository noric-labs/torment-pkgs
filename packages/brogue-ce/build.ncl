let { subsetOf, Attrs, BuildSpec, Local, OutputBin, OutputData, Source, Test, .. } = import "minimal.ncl" in
let base = import "../base/build.ncl" in
let gcc = import "../gcc/build.ncl" in
let glibc = import "../glibc/build.ncl" in
let llvm = import "../llvm/build.ncl" in
let make = import "../make/build.ncl" in
let ncurses = import "../ncurses/build.ncl" in
let tmux = import "../tmux/build.ncl" in
let toolchain = import "../toolchain/build.ncl" in

# Terminal-only (ncurses) Brogue CE, two binaries:
#   brogue-ce       gcc -O2 release build
#   brogue-ce-asan  clang -O1 -g, -fsanitize=address,undefined (static clang rt)
# Needs a terminal of at least 100x34; smaller shows a blocking "resize" screen.
# Saves (*.broguesave), recordings (*.broguerec), BrogueHighScores.txt and
# keymap.txt all resolve relative to the cwd, so run it from a writable dir.
# DATADIR=/usr/share/brogue-ce is baked in but only used by SDL tiles.
let version = "1.15.1" in
{
  name = "brogue-ce",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://github.com/tmewett/BrogueCE/archive/refs/tags/v%{version}.tar.gz",
      sha256 = "2abc186c5327342cb9ad7e45d41096ab10797d5ba76dcac843824ac2a0bfb3ac",
      extract = true,
      strip_prefix = "BrogueCE-%{version}",
    } | Source,
    base,
    llvm,
    make,
    toolchain,
  ],
  runtime_deps = [
    glibc,
    subsetOf gcc ["libgcc"],
    subsetOf ncurses ["libncurses", "terminfo"],
  ],

  cmd = "./build.sh",
  build_args = { include version },

  outputs = {
    bins = { glob = "usr/bin/brogue-ce" } | OutputBin,
    asan = { glob = "usr/bin/brogue-ce-asan" } | OutputBin,
    data = { glob = "usr/share/brogue-ce/**" } | OutputData,
    license = { glob = "usr/share/licenses/brogue-ce/*" } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "AGPL-3.0-or-later",
      source_provenance = {
        category = 'GithubRepo,
        owner = "tmewett",
        repo = "BrogueCE",
      },
    } | Attrs,

  tests = {
    version =
      {
        class = 'Standalone,
        test_deps = [base],
        cmds = [["/bin/bash", "-c", "brogue-ce --version | grep -q 'CE %{version}'"]],
      } | Test,
    dungeon_draws =
      {
        class = 'Standalone,
        test_deps = [base, tmux],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -e
          cd "$(mktemp -d)"
          export TERM=xterm-256color ASAN_OPTIONS=detect_leaks=0:abort_on_error=1
          printf 'set -g window-size manual\nset -g default-size 100x34\n' > tmux.conf
          for b in brogue-ce brogue-ce-asan; do
            tmux -L brogue-test -f tmux.conf new-session -d -s $b -x 100 -y 34 "$b -t -s 42 -n 2>$b.err; sleep 30"
          done
          sleep 4
          for b in brogue-ce brogue-ce-asan; do
            tmux -L brogue-test send-keys -t $b x; sleep 2
            tmux -L brogue-test capture-pane -p -t $b > $b.txt
            grep -q 'Depth: 1' $b.txt
            grep -q '@' $b.txt
            if grep -q 'Sanitizer' $b.err; then cat $b.err; exit 1; fi
          done
          tmux -L brogue-test kill-server
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
