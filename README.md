# Bazel rules for mise

A Bazel module that exposes tools installed via [mise](https://mise.jdx.dev/) as
Bazel dependencies. It is an alternative to
[rules_multitool](https://github.com/bazel-contrib/rules_multitool) that reuses
your existing `mise.lock` instead of maintaining a separate lockfile. The same
`mise.toml` / `mise.lock` drives both your local developer environment
(`mise install`) and your Bazel toolchains, so tools don't have to run through
Bazel to stay pinned to the same version — handy for linters and other dev tools
you also run outside Bazel (see `e2e/smoke`, which uses `ruff` both ways).

It also supports mise's `conda:` backend, which covers many tools that don't
ship easily usable statically compiled binaries — e.g. PostgreSQL
(`conda:postgresql`, see `e2e/conda`).

## Conda environments

Each `conda:` tool gets its own conda prefix, which is not enough for
PostgreSQL extensions: `pgvector` installs `lib/vector.so` and
`share/extension/vector.control`, and a server can only load them from its own
prefix. Adding both `conda:postgresql` and `conda:pgvector` to a lockfile
leaves them in separate prefixes, so `CREATE EXTENSION vector` fails.

`mise.conda_env` installs several conda packages into a single prefix instead:

```starlark
mise = use_extension("@rules_mise//mise:extensions.bzl", "mise")
mise.hub(lockfile = "//:mise.lock")
mise.conda_env(
    name = "pg",
    lockfile = "//:mise.lock",
    tools = [
        "conda:postgresql@18.4",
        "conda:pgvector@0.8.1",
    ],
)
use_repo(mise, "mise")
```

Each environment is exposed as a tool of its own, keyed
`conda_env_<name>`, with the same targets as any other tool:

```text
@mise//tools/conda_env_pg:tool  -> runs any binary in the merged prefix
```

`tools` entries are mise tool names with an optional `@version`, resolved
against the same `mise.lock`. An environment holds one build of each conda
package, so members whose closures disagree (here `libpq` 18.4 vs 18.6) are
merged by package name with the highest version winning, and each dropped
build is reported. A platform is only offered when every member has a build
for it. See `e2e/conda-env`.

## Usage

In your `MODULE.bazel`:

```starlark
mise = use_extension("@rules_mise//mise:extensions.bzl", "mise")
mise.hub(lockfile = "//:mise.lock")
use_repo(mise, "mise")

register_toolchains("@mise//toolchains:all")
```

Then depend on tools through the toolchain-resolved targets:

```text
@mise//tools/ruff:tool            -> ruff for the current platform
@mise//tools/ruff:cwd             -> wrapper running ruff from the current directory
@mise//tools/ruff:workspace_root  -> wrapper running ruff from $BUILD_WORKSPACE_DIRECTORY
@mise//tools/conda_postgresql:tool -> conda wrapper for prefix bin/ binaries
```

Only lockfile entries with a downloadable `url` on a supported
platform (`linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`,
`windows-x64`) are exposed; anything else is skipped with a warning.
`linux-*-musl` entries are ignored (folded into the non-musl entry).
A `checksum` is used when the lockfile records one; entries without a
checksum (e.g. `http:` backends) are still exposed, but the download cannot
be verified and the tool repo is marked non-reproducible.

## Supported mise backends

`rules_mise` exposes tools whose lockfile entries contain direct download
URLs. That covers these backends (all exercised in `e2e/backends`, except
`conda` which is exercised in `e2e/conda`):

| Backend    | Supported          | Notes                                                               |
| ---------- | ------------------ | ------------------------------------------------------------------- |
| `aqua`     | yes                | includes registry shorthand entries such as `ruff = "latest"`       |
| `conda`    | yes (experimental) | needs a conda-forge package, see `e2e/conda`                        |
| `core`     | yes                | e.g. `bun`, `node`                                                  |
| `forgejo`  | yes                | self-hosted instances via the `api_url` tool option                 |
| `github`   | yes                |                                                                     |
| `gitlab`   | yes                |                                                                     |
| `http`     | yes                | records no checksums: downloads are unverified and non-reproducible |
| `packslip` | yes                |                                                                     |

These backends record no usable URLs in `mise.lock` (they install via a
language runtime, plugin scripts, or install-time API resolution), so
supporting them would require significant additional work and they are
skipped with a warning: `asdf`, `cargo`, `dotnet`, `gem`, `go`,
`npm`, `pipx`, `s3`, `spm`, `ubi`, `vfox`. Single-file-compressed assets
such as `taplo`'s `.gz` files (as opposed to `.tar.gz` archives) are also
skipped.

## Installation

From the release you wish to use:
<https://github.com/rules_mise/rules_mise/releases>
copy the Bzlmod snippet into your `MODULE.bazel` file.

To use a commit rather than a release, you can point at any SHA of the repo with
an `archive_override` in MODULE.bazel.

For example to use commit `abc123`:

```starlark
archive_override(
    module_name = "rules_mise",
    url = "https://github.com/rules_mise/rules_mise/archive/abc123.tar.gz",
    strip_prefix = "rules_mise-abc123",
    # The easiest way to set this is to comment out this line, then Bazel will print
    # a message with the correct value. Note that GitHub archives lack a strong
    # guarantee on the sha256 stability, see <https://github.blog/2023-02-21-update-on-the-future-stability-of-source-code-archives-and-hashes/>
    integrity = "...",
)
```
