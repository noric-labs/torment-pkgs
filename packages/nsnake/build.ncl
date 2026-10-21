let { upstream, subsetOf, Attrs, BuildSpec, Local, OutputBin, OutputData, Source, Test, .. } = import "minimal.ncl" in
let base = upstream "base" in
let gcc = upstream "gcc" in
let glibc = upstream "glibc" in
let llvm = upstream "llvm" in
let make = upstream "make" in
let ncurses = upstream "ncurses" in
let tmux = upstream "tmux" in
let toolchain = upstream "toolchain" in

# nSnake (C++/ncurses real-time snake), two binaries:
#   nsnake       g++ -O2 release build
#   nsnake-asan  clang++ -O1 -g, -fsanitize=address,undefined
# Needs a terminal of at least 80x24; smaller exits with status 1.
# Settings (settings.ini), scores (arcade.nsnakescores) and user levels live in
# $HOME/.local/share/nsnake/ (created on start; /tmp/.local/share/nsnake/
# without $HOME). The RNG is srand(time(NULL)): there is no seed option.
# Bundled levels are installed to /usr/share/games/nsnake/levels; the game only
# reads levels from the user dir, so copy them there to use "Level Select".
let version = "3.0.1" in
{
  name = "nsnake",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://github.com/alexdantas/nSnake/archive/refs/tags/v%{version}.tar.gz",
      sha256 = "7240dafe35e17b01134591d7ae8f09f5a375cded8b01e43ba97ca3610a09ea61",
      extract = true,
      strip_prefix = "nSnake-%{version}",
    } | Source,
    base,
    llvm,
    make,
    toolchain,
  ],
  runtime_deps = [
    glibc,
    subsetOf gcc ["libgcc", "libstdcpp"],
    subsetOf ncurses ["libncurses", "terminfo"],
  ],

  cmd = "./build.sh",
  build_args = { include version },

  outputs = {
    bins = { glob = "usr/bin/nsnake" } | OutputBin,
    asan = { glob = "usr/bin/nsnake-asan" } | OutputBin,
    levels = { glob = "usr/share/games/nsnake/levels/*" } | OutputData,
    license = { glob = "usr/share/licenses/nsnake/*" } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "GPL-3.0-or-later",
      source_provenance = {
        category = 'GithubRepo,
        owner = "alexdantas",
        repo = "nSnake",
      },
    } | Attrs,

  tests = {
    game_draws =
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
          for b in nsnake nsnake-asan; do
            tmux -L nsnake-test -f tmux.conf new-session -d -s $b -x 80 -y 24 "$b 2>$b.err; sleep 30"
          done
          sleep 3
          for b in nsnake nsnake-asan; do
            tmux -L nsnake-test send-keys -t $b Enter; sleep 2
            tmux -L nsnake-test capture-pane -p -t $b > $b.txt
            grep -q 'Hi-Score' $b.txt
            if grep -q 'Sanitizer' $b.err; then cat $b.err; exit 1; fi
          done
          tmux -L nsnake-test kill-server
          test -d .local/share/nsnake/levels
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
