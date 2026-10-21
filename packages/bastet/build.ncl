let { upstream, subsetOf, Attrs, BuildSpec, Local, OutputBin, OutputData, Source, Test, .. } = import "minimal.ncl" in
let base = upstream "base" in
let boost = upstream "boost" in
let gcc = upstream "gcc" in
let glibc = upstream "glibc" in
let llvm = upstream "llvm" in
let make = upstream "make" in
let ncurses = upstream "ncurses" in
let tmux = upstream "tmux" in
let toolchain = upstream "toolchain" in

# Bastet ("bastard tetris"), C++/ncurses + boost_program_options. Two binaries:
#   bastet       g++ -O2 release build
#   bastet-asan  clang++ -O1 -g, -fsanitize=address,undefined (static clang rt)
# Real-time: pieces fall on a select() timeout. Needs >= 24 rows and ~40 cols;
# smaller terminals silently lose the well window. No SIGWINCH handling.
# RNG: srandom(time(NULL)+37) at startup, no seed option.
# High scores go to $HOME/.bastetscores (upstream's fallback when
# /var/games/bastet.scores2 is not writable); key config in $HOME/.bastetrc.
# Both print a line or two to stderr at startup, so redirect stderr.
let version = "0.43.2" in
{
  name = "bastet",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://github.com/fph/bastet/archive/refs/tags/%{version}.tar.gz",
      sha256 = "f219510afc1d83e4651fbffd5921b1e0b926d5311da4f8fa7df103dc7f2c403f",
      extract = true,
      strip_prefix = "bastet-%{version}",
    } | Source,
    base,
    boost,
    llvm,
    make,
    toolchain,
  ],
  runtime_deps = [
    glibc,
    subsetOf boost ["libs"],
    subsetOf gcc ["libgcc", "libstdcpp"],
    subsetOf ncurses ["libncurses", "terminfo"],
  ],

  cmd = "./build.sh",

  outputs = {
    bins = { glob = "usr/bin/bastet" } | OutputBin,
    asan = { glob = "usr/bin/bastet-asan" } | OutputBin,
    license = { glob = "usr/share/licenses/bastet/*" } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "GPL-3.0-or-later",
      source_provenance = {
        category = 'GithubRepo,
        owner = "fph",
        repo = "bastet",
      },
    } | Attrs,

  tests = {
    well_draws =
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
          export HOME=$PWD TERM=xterm-256color ASAN_OPTIONS=detect_leaks=0:abort_on_error=1
          printf 'set -g window-size manual\nset -g default-size 80x24\n' > tmux.conf
          for b in bastet bastet-asan; do
            tmux -L bastet-test -f tmux.conf new-session -d -s $b -x 80 -y 24 "$b 2>$b.err; sleep 30"
          done
          sleep 3
          for b in bastet bastet-asan; do
            tmux -L bastet-test send-keys -t $b Enter; sleep 3
            tmux -L bastet-test capture-pane -p -t $b > $b.txt
            grep -q 'Next block' $b.txt
            grep -q 'Score:' $b.txt
            if grep -q 'Sanitizer' $b.err; then cat $b.err; exit 1; fi
          done
          test -f "$HOME/.bastetscores"
          tmux -L bastet-test kill-server
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
