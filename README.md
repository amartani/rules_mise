# Bazel rules for mise

A Bazel module that exposes tools installed via [mise](https://mise.jdx.dev/) as Bazel dependencies.
It is an alternative to [rules_multitool](https://github.com/bazel-contrib/rules_multitool) that reuses your existing `mise.lock` instead of maintaining a separate lockfile.
The same `mise.toml` / `mise.lock` drives both your local developer environment (`mise install`) and your Bazel toolchains, so tools don't have to run through Bazel to stay pinned to the same version — handy for linters and other dev tools you also run outside Bazel (see `e2e/smoke`, which uses `ruff` both ways).

It also supports mise's `pkgx:` backend, which covers many tools that don't ship easily usable statically compiled binaries — e.g. PostgreSQL (`pkgx:postgresql.org`, see `e2e/pkgx`).

## Usage

In your `MODULE.bazel`:

```starlark
mise = use_extension("@rules_mise//mise:extensions.bzl", "mise")
mise.hub(lockfile = "//:mise.lock")
use_repo(mise, "mise")

register_toolchains("@mise//toolchains:all")
```

Then depend on tools through the toolchain-resolved targets:

```
@mise//tools/ruff:tool            -> ruff for the current platform
@mise//tools/ruff:cwd             -> wrapper running ruff from the current directory
@mise//tools/ruff:workspace_root  -> wrapper running ruff from $BUILD_WORKSPACE_DIRECTORY
@mise//tools/pkgx_postgresql.org:psql  -> pkgx-provided binary via the dispatcher
```

Only lockfile entries with both `url` and `checksum` on a supported
platform (`linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`,
`windows-x64`) are exposed; anything else is skipped with a warning.
`linux-*-musl` entries are ignored (folded into the non-musl entry).

## Installation

From the release you wish to use:
<https://github.com/rules_mise/rules_mise/releases>
copy the Bzlmod snippet into your `MODULE.bazel` file.

To use a commit rather than a release, you can point at any SHA of the repo with an `archive_override` in MODULE.bazel.

For example to use commit `abc123`:

```starlark
archive_override(
    module_name = "rules_mise",
    url = "https://github.com/rules_mise/rules_mise/archive/abc123.tar.gz",
    strip_prefix = "rules_mise-abc123",
    # The easiest way to set this is to comment out this line, then Bazel will print
    # a message with the correct value. Note that GitHub source archives don't have a strong
    # guarantee on the sha256 stability, see <https://github.blog/2023-02-21-update-on-the-future-stability-of-source-code-archives-and-hashes/>
    integrity = "...",
)
```
