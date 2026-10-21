let { Attrs, BuildSpec, Local, OutputData, Source, Test, .. } = import "minimal.ncl" in
let base = import "../base/build.ncl" in

# Microsoft released Zork I-III under the MIT license on 2025-11-20; each
# historicalsource repo ships the compiled story file in COMPILED/.
let zork1_commit = "97b7b3d68c075dd9af7da499c3e9690ada3471fd" in
let zork2_commit = "3da9661098809788a99cef00f00c865c6c204f96" in
let zork3_commit = "3ec9ed412b5f3cafe65d83c727d07db1fe4a86a8" in
{
  name = "zork-stories",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://github.com/historicalsource/zork1/archive/%{zork1_commit}.tar.gz",
      sha256 = "06ae7ae8eda6022b6cc122ee202c56915c6312a7facac95785edf11ee2c5894d",
      extract = true,
    } | Source,
    {
      url = "https://github.com/historicalsource/zork2/archive/%{zork2_commit}.tar.gz",
      sha256 = "1cf8cf89d54ec8927e9a9086fde055d24da2c70be4106e770a04119e52b0e672",
      extract = true,
    } | Source,
    {
      url = "https://github.com/historicalsource/zork3/archive/%{zork3_commit}.tar.gz",
      sha256 = "f494517b6942acae2272b6322ba648b9f1a1c7a9ee496c1cce671786cf94875d",
      extract = true,
    } | Source,
    base,
  ],

  cmd = "./build.sh",
  build_args = {
    include zork1_commit,
    include zork2_commit,
    include zork3_commit,
  },

  outputs = {
    stories = { glob = "usr/share/zork/zork{1,2,3}.z3" } | OutputData,
    licenses = { glob = "usr/share/licenses/zork-stories/*" } | OutputData,
  },

  attrs =
    {
      # Three upstream repos (historicalsource/zork{1,2,3}), so no single
      # source_provenance applies.
      license_spdx = "MIT",
    } | Attrs,

  tests = {
    story_headers =
      {
        class = 'Standalone,
        test_deps = [base],
        cmds = [
          [
            "/bin/bash",
            "-c",
            m%"
          set -e
          for n in 1 2 3; do
            # Byte 0 of a Z-machine story is its version: 3.
            [ "$(od -An -tu1 -N1 /usr/share/zork/zork$n.z3 | tr -d ' ')" = 3 ]
          done
          echo OK
        "%
          ],
        ],
      } | Test,
  },
} | BuildSpec
