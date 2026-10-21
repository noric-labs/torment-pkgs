let { upstream, subsetOf, Attrs, BuildSpec, Local, OutputBin, OutputData, Source, Test, .. } = import "minimal.ncl" in
let base = upstream "base" in
let gcc = upstream "gcc" in
let glibc = upstream "glibc" in
let llvm = upstream "llvm" in
let ncurses = upstream "ncurses" in
let tmux = upstream "tmux" in
let toolchain = upstream "toolchain" in

# Pacman for Console (ncurses), two binaries:
#   pacman4console       gcc -O2 release build
#   pacman4console-asan  clang -O1 -g, -fsanitize=address,undefined (static clang rt)
# Needs a terminal of at least 29 cols x 32 rows; smaller prints "Sorry" and
# exits 0. Real time: a busy-wait tick of ~175 ms (100% CPU), ghosts use
# rand() seeded with srand(time(NULL)). No args: intro, then the 9 built-in
# levels from /usr/share/pacman4console/pacman/Levels/. A level file path as
# argv[1] (truncated to 99 chars) plays just that level, skipping the intro.
# Game over, q and a missing level file all exit 0.
let version = "1.3" in
{
  name = "pacman4console",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://deb.debian.org/debian/pool/main/p/pacman4console/pacman4console_%{version}.orig.tar.gz",
      sha256 = "9a5c4a96395ce4a3b26a9896343a2cdf488182da1b96374a13bf5d811679eb90",
      extract = true,
      strip_prefix = "pacman-%{version}",
    } | Source,
    base,
    llvm,
    ncurses,
    toolchain,
  ],
  runtime_deps = [
    glibc,
    subsetOf gcc ["libgcc"],
    subsetOf ncurses ["libncurses", "terminfo"],
  ],

  cmd = "./build.sh",

  outputs = {
    bins = { glob = "usr/bin/pacman4console" } | OutputBin,
    asan = { glob = "usr/bin/pacman4console-asan" } | OutputBin,
    data = { glob = "usr/share/pacman4console/**" } | OutputData,
    license = { glob = "usr/share/licenses/pacman4console/*" } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "GPL-2.0-or-later",
    } | Attrs,

  tests = {
    maze_draws =
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
          printf 'set -g window-size manual\nset -g default-size 29x32\n' > tmux.conf
          for b in pacman4console pacman4console-asan; do
            tmux -L pac-test -f tmux.conf new-session -d -s $b -x 29 -y 32 "$b 2>$b.err; sleep 30"
          done
          sleep 2
          for b in pacman4console pacman4console-asan; do
            tmux -L pac-test capture-pane -p -t $b | grep -q 'Press any key'
            tmux -L pac-test send-keys -t $b x; sleep 3
            tmux -L pac-test capture-pane -p -t $b > $b.txt
            grep -q 'Level: 1' $b.txt
            grep -q 'Score:' $b.txt
            grep -q '&' $b.txt
            if grep -q 'Sanitizer' $b.err; then cat $b.err; exit 1; fi
          done
          tmux -L pac-test kill-server
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
