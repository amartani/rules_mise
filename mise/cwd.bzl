"""Mise execution rule that runs a tool from Bazel's client working directory.

`cwd` wraps an executable tool target (typically a hub `tool` such as
`@mise//tools/ruff:tool`) into an executable wrapper that `exec`s the tool with
its working directory set to `$PWD` — the directory from which Bazel was
invoked — so the tool processes the user's files instead of Bazel's execroot or
runfiles directory. The wrapper locates the tool next to itself first, then
through `$RUNFILES_DIR` / `$RUNFILES_MANIFEST_FILE`, and finally through the
workspace-relative short path; it fails with a clear message if none of these
resolves. See `//mise/private:run_in` for the shared implementation.
"""

load("@rules_mise//mise/private:cwd.bzl", _cwd = "cwd")

cwd = _cwd
