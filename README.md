# Bazel rules for mise

A Bazel module that exposes tools installed via [mise](https://mise.jdx.dev/) as Bazel dependencies.
It is an alternative to [rules_multitool](https://github.com/bazel-contrib/rules_multitool) that reuses your existing `mise.lock` instead of maintaining a separate lockfile.
The same `mise.toml` / `mise.lock` drives both your local developer environment (`mise install`) and your Bazel toolchains, so tools don't have to run through Bazel to stay pinned to the same version — handy for linters and other dev tools you also run outside Bazel (see `e2e/smoke`, which uses `ruff` both ways).

It also supports mise's `pkgx:` backend, which covers many tools that don't ship easily usable statically compiled binaries — e.g. PostgreSQL (`pkgx:postgresql.org`, see `e2e/pkgx`).

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
