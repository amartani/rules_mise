"""Mise execution rule that runs a tool from the directory `bazel run` was invoked from.

`cwd` wraps an executable tool target (typically a hub `tool` such as
`@mise//tools/ruff:tool`) into an executable wrapper that `exec`s the tool with
its working directory set to `$BUILD_WORKING_DIRECTORY` — the directory from
which `bazel run` was invoked — so the tool processes the user's files instead
of Bazel's execroot or runfiles directory. When the wrapper is run directly
rather than through `bazel run`, it stays in the current directory. The wrapper
locates the tool next to itself first, then through `$RUNFILES_DIR` /
`$RUNFILES_MANIFEST_FILE`, and finally through the workspace-relative short
path; it fails with a clear message if none of these resolves. See
`//mise/private:run_in` for the shared implementation.
"""

load("@rules_mise//mise/private:cwd.bzl", _cwd = "cwd")

cwd = _cwd
