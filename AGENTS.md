# AGENTS.md

## Commands

```bash
bazel build //...          # root workspace
bazel test //...           # root workspace (CI also runs with Bazel 8.x and 9.x via USE_BAZEL_VERSION)

# e2e/* are SEPARATE Bazel workspaces (excluded via .bazelignore) — cd in first:
cd e2e/smoke && bazel test //...
cd e2e/backends && bazel test //...
cd e2e/conda && bazel test //...
cd e2e/itest && bazel test //...

bazel run //:gazelle                    # regenerate bzl_library deps after touching .bzl load stmts
bazel mod tidy --lockfile_mode=refresh  # only way to update MODULE.bazel.lock (.bazelrc sets --lockfile_mode=error)

mise install && hk install --mise  # one-time lint setup (CONTRIBUTING.md)
mise exec -- hk check --all        # what CI's hk job runs (buildifier, prettier, taplo, yamlfmt, typos)
```

## Architecture

- Bzlmod-only, no WORKSPACE. Entry: `mise/extensions.bzl` (`mise.hub(lockfile, hub_name)`).
- `mise/private/lockfile.bzl` parses `mise.lock` TOML (`toml.bzl`); `mise/hub.bzl` (`bzlmod_hub`/`workspace_hub`) creates one tool repo per platform plus a toolchain hub. Consumer pattern (see `e2e/smoke/MODULE.bazel`): `mise.hub(lockfile = "//:mise.lock")`, `use_repo(mise, "mise")`, `register_toolchains("@mise//toolchains:all")`.
- Tool targets: `@mise//tools/<name>:tool` plus `:cwd`, `:workspace_root`. conda tools (e.g. `conda:postgresql`) expose a wrapper dispatching to the conda prefix's `bin/` via the first argument (e.g. `tool psql --version`) and via `argv[0]` for per-binary symlinks.
- Tool-name sanitizing (`lockfile.bzl` `_clean`): only `: / + @` and space become `_`; `-` and `.` are kept (e.g. `npm:prettier` → `npm_prettier`). Keep in sync when adding lookups.
- Multi-version tools (`"conda:postgresql" = ["17.7", "18.4"]`, one `[[tools.*]]` entry per version) become one Bazel tool per version (`_tool_key`: `<tool>@<version>` → e.g. `conda_postgresql_17.7`); single-version keys are unchanged.
- Lockfile gotchas: `linux-*-musl` entries are ignored (folded into non-musl); entries without `url`+`checksum` are silently skipped; only linux/macOS/windows x64+arm64 (no macos-musl, no windows-arm64) are recognized. conda tools additionally carry `conda_deps` per platform, resolved against a shared `[conda-packages.<platform>]` lockfile section (`.conda` outer zip + inner `pkg-*.tar.zst`, `.tar.bz2` direct). `mise.lock` is `@generated` by `mise lock` — bump versions in `mise.toml`, don't hand-edit.

## Conventions

- Leave `version`/`compatibility_level` unset in root `MODULE.bazel` (release automation patches them for the BCR).
- Commit messages must be conventional commits — enforced by `hk.pkl` `commit-msg` hook; releases are fully automated from history.
- `e2e/smoke` is the BCR presubmit module (`.bcr/presubmit.yml`) and must stay minimal/consumer-shaped; use `local_path_override` to `../..` there, never a registry version.
- Renovate manages `mise.lock` (`lockFileMaintenance`) but `MODULE.bazel` updates are disabled — bump Bazel deps by hand.
- External docs via context7 MCP: `/bazelbuild/bazel`, `/bazel-contrib/rules_multitool`, `/bazelbuild/bazel-skylib`, `/bazel-contrib/bazel-lib`, `/jdx/mise`, `/jdx/hk`. Verify new module versions in the Bazel Central Registry before adding.
