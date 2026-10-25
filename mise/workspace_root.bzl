"""Mise execution rule that runs a tool from the workspace root.

`workspace_root` wraps an executable tool target (typically a hub `tool` such
as `@mise//tools/ruff`) into an executable wrapper that `exec`s the tool
with its working directory set to `$BUILD_WORKSPACE_DIRECTORY` — the workspace
root — so the tool sees the whole workspace regardless of where Bazel was
invoked from. The wrapper locates the tool next to itself first, then through
`$RUNFILES_DIR` / `$RUNFILES_MANIFEST_FILE`, and finally through the
workspace-relative short path; it fails with a clear message if none of these
resolves. See `//mise/private:run_in` for the shared implementation.
"""

load("@rules_mise//mise/private:workspace_root.bzl", _workspace_root = "workspace_root")

workspace_root = _workspace_root
