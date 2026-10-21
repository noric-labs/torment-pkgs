let { upstream, subsetOf, Attrs, BuildSpec, Local, Needs, OutputBin, OutputData, Source, .. } = import "minimal.ncl" in
let base = upstream "base" in
let coreutils = upstream "coreutils" in
let node-lts = upstream "node-lts" in

# pi is the Pi coding agent (pi.dev), published to npm as
# @earendil-works/pi-coding-agent. It is installed from the sha256-pinned
# registry tarball (the Source below) rather than built from the GitHub
# monorepo, whose build needs the tsgo native TS compiler and a multi-package
# workspace, neither of which is warranted for an npm artifact. The tarball
# ships an npm-shrinkwrap.json, so installing it locks the transitive
# dependency tree and keeps the build reproducible. The `#!/usr/bin/env node`
# shebang of the installed bin is served by coreutils(env) + node.
# Sideloaded ahead of upstream (gominimal/pkgs has 1.0.2); nexus lanes need 1.3.0.
let version = "1.3.0" in
{
  name = "pi",
  build_deps = [
    { file = "build.sh" } | Local,
    {
      url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-%{version}.tgz",
      sha256 = "ae2785e870b81a8c8e1d44510a57b5ee0bfc9e974679ac2faaada4aabee3d3c0",
    } | Source,
    base,
    node-lts,
  ],
  runtime_deps = [
    coreutils,
    subsetOf node-lts ["node"],
  ],
  needs =
    {
      dns = {},
      internet = {},
    } | Needs,

  cmd = "./build.sh",
  build_args = {
    include version,
  },

  outputs = {
    pi = { glob = "usr/bin/pi" } | OutputBin,
    libexec = { glob = "usr/libexec/pi/**", allow_executable = true } | OutputData,
  },

  attrs =
    {
      upstream_version = version,
      license_spdx = "MIT",
      source_provenance = {
        category = 'GithubRepo,
        owner = "earendil-works",
        repo = "pi",
      },
    } | Attrs,
} | BuildSpec
