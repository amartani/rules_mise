# rules_mise Architecture

## Overview

`rules_mise` is a Bazel module that allows using tools from [mise](https://mise.jdx.dev/) directly in Bazel BUILD files. It parses the `mise.lock` file to discover tool versions and their download URLs, then makes those tools available as Bazel targets behind toolchain resolution.

## Core Concepts

### 1. Lockfile Format

The `mise.lock` file is a `@generated` TOML file (bump versions in `mise.toml`, don't hand-edit). Example:

```toml
[[tools.ruff]]
version = "0.16.7"
backend = "aqua:astral-sh/ruff"

[tools.ruff."platforms.linux-x64"]
url = "https://github.com/astral-sh/ruff/releases/download/0.16.7/ruff-x86_64-unknown-linux-musl.tar.gz"
checksum = "sha256:8d28939cf5cabe54a2f8f7cbfab52c643436d1bc70474198181db9e48f504411"
```

Key aspects (see `mise/private/lockfile.bzl`):

- Tools are `[[tools.<name>]]` (array of tables) or a single `[tools.<name>]` table; each entry has `version`, `backend`, and `platforms.<os>-<arch>` subtables.
- Recognized platforms: `linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`, `windows-x64`. `linux-*-musl` entries are ignored (folded into the non-musl entry); anything else is skipped.
- Entries without both `url` and `checksum` are silently skipped. `sha256:` prefixes are stripped before use.
- Tool names are sanitized for Bazel (`_clean`): only `:`, `/`, `+`, `@`, and space become `_`; `-` and `.` are kept (e.g. `npm:prettier` → `npm_prettier`).
- pkgx tools (`backend = "pkgx:..."`) additionally carry `pkgx_deps` / `pkgx_provides` / `pkgx_runtime_env` per platform, resolved against a shared `[pkgx-packages.<platform>]` lockfile section. Only `bin/` and `sbin/` provides become Bazel targets.

### 2. Module Extension

The module extension (`mise/extensions.bzl`) provides the entry point. It accepts a `hub` tag:

- `lockfile`: label of a `mise.lock` file (mandatory, single file).
- `hub_name`: name of the hub repository (defaults to `"mise"`).

```python
mise = use_extension("@rules_mise//mise:extensions.bzl", "mise")
mise.hub(lockfile = "//:mise.lock")
use_repo(mise, "mise")

register_toolchains("@mise//toolchains:all")
```

The extension collects lockfiles per `hub_name` across modules (later modules win), so multiple lockfiles / modules can feed one hub. It ensures the default `mise` hub is a direct dep, and reports `reproducible = True` metadata.

### 3. Per-Platform Tool Repositories

`bzlmod_hub()` (`mise/hub.bzl`) creates one `tool_repo` per tool per platform, named `{hub}.{tool}.{os}_{cpu}` (e.g. `mise.ruff.linux_x86_64`). Each downloads and prepares its own binary:

- `kind = "file"`: `rctx.download()` straight to `tools/<tool>/<os>_<cpu>_executable[.exe]`.
- `kind = "archive"` (`.tar.gz`, `.tgz`, `.tar.xz`, `.tar.bz2`, `.tar`, `.zip`): `download_and_extract`, then locate the executable — explicit `file` attribute first, then `<tool-name>` pattern matches, then first executable file — and symlink it to the `..._executable` path.
- `kind = "pkg"` (macOS installer packages): expanded with `pkgutil --expand-full` (macOS-only; requires `pkgutil`, marked non-reproducible).
- pkgx tools: every bottle in the closure (transitive deps first, root last) is extracted under `tools/<tool>/pkgx-root/<package>/v<version>/`, reproducing mise's install layout. A generated bash dispatcher (`<os>_<cpu>_executable`) sets the pantry runtime environment (`PATH`, `LD_LIBRARY_PATH`, `CPATH`, …, plus per-package `pkgx_runtime_env` with `{{prefix}}` substituted) and dispatches on `argv[0]` so all provided binaries share one toolchain. Windows pkgx is unsupported and fails fast.

Downloads honor private registries via netrc (`NETRC` env / user netrc matched against per-URL auth patterns), and forward `headers` on Bazel versions that support `download_has_headers_param`. Extracted pkgx file lists are enumerated explicitly (files + symlinks, never directories); symlink cycles are dropped since neither globs nor runfiles trees can traverse them.

### 4. Hub Repository

The `_mise_hub` repository itself contains no binaries — it declares toolchains and the user-facing rules:

- `toolchain_info.bzl` — `toolchain_info` rule (`executable`, `os`, `cpu`, `ext`, `files`) plus `declare_toolchain()`, which wires each `tool_repo` executable into `exec` + `target` toolchains constrained on `@platforms//os:{os}` / `@platforms//cpu:{cpu}`.
- `toolchains/BUILD.bazel` — calls every tool's `declare_toolchains()`. Users register them with `register_toolchains("@mise//toolchains:all")`.
- `tools/<tool>/tool.bzl` — a `tool` rule that resolves `//tools/<tool>:toolchain_type` and symlinks the selected toolchain executable to its own output (plus runfiles, so pkgx closures travel with it).
- `tools/<tool>/BUILD.bazel` — `toolchain_type`, `:tool`, plus `:cwd` and `:workspace_root` wrappers (below). pkgx tools additionally declare one `tool()` target per provided binary (`:psql`, `:pg_ctl`, …), all sharing the dispatcher via `argv[0]`.
- `tools.bzl` — `TOOLS` label map + `register_tools()` for non-bzlmod `WORKSPACE` usage (`workspace_hub()` path).

### 5. Tool Usage

Tools resolve through the toolchain, so the same label picks the right binary per execution platform:

```
@mise//tools/ruff:tool                          -> ruff for the current platform
@mise//tools/ruff:cwd                           -> wrapper running ruff with $PWD = Bazel's cwd
@mise//tools/ruff:workspace_root                -> wrapper running ruff with $BUILD_WORKSPACE_DIRECTORY
@mise//tools/pkgx_postgresql.org:psql           -> pkgx-provided binary via the dispatcher
```

`:cwd` / `:workspace_root` (`mise/private/run_in.bzl`) expand a small wrapper script (`.sh`, or `.bat` for `.exe` tools) that sets `PWD` / `BUILD_WORKSPACE_DIRECTORY` and execs the resolved tool.

## File Structure

```
mise/
├── BUILD.bazel              # bzl_library targets: extensions, hub, cwd, workspace_root
├── extensions.bzl           # module extension (hub tag -> bzlmod_hub)
├── hub.bzl                  # bzlmod_hub / workspace_hub, tool_repo, _mise_hub, pkgx dispatcher
├── cwd.bzl / workspace_root.bzl  # public re-exports of the private wrappers
└── private/
    ├── lockfile.bzl         # mise.lock parsing, platform map, name sanitizing, pkgx payloads
    ├── templates.bzl        # hub/tools.bzl rendering, host-constraint mapping
    ├── run_in.bzl           # shared cwd/workspace_root wrapper implementation
    ├── cwd.bzl / workspace_root.bzl
    ├── run_in.template.sh / run_in.template.bat
    ├── hub_repo_template/   # BUILD / toolchain_info.bzl / tools.bzl / toolchains+tools shells
    ├── hub_repo_tool_template/  # (currently unused: hub.bzl inlines tool.bzl/BUILD content)
    └── tool_repo_template/  # (currently unused: hub.bzl writes executables directly)
```

## Data Flow

1. **User configuration** (`MODULE.bazel`): `mise.hub(lockfile = "//:mise.lock")`, `use_repo(mise, "mise")`, `register_toolchains("@mise//toolchains:all")`.
2. **Extension execution** (`extensions.bzl`): gathers lockfile labels per hub, calls `bzlmod_hub(name, lockfiles, module_ctx)`.
3. **Tool repo creation** (`bzlmod_hub`): parses the lockfiles via `lockfile.load_defs()`, instantiates one `tool_repo` per binary (JSON-encoded binary descriptor), then creates `_mise_hub` with the lockfile labels.
4. **Repository fetching** (`tool_repo` impl): downloads/verifies/extracts per §3; pkgx repos additionally write the dispatcher and an explicit-srcs `pkgx_files` filegroup.
5. **Hub generation** (`_mise_hub_impl`): renders `toolchain_info.bzl`, root/tool `BUILD` files, per-tool `tool.bzl` + `BUILD.bazel`, `toolchains/BUILD.bazel`, and `tools.bzl`.
6. **Build usage**: `@mise//tools/<tool>:tool` resolves through the registered toolchain for the execution platform.

## Key Implementation Details

### Platform Mapping

Mise platform suffixes map to toolchain `os`/`cpu` strings, which become `@platforms//os:{os}` / `@platforms//cpu:{cpu}` constraints:

| Mise Platform | os      | cpu     |
| ------------- | ------- | ------- |
| linux-x64     | linux   | x86_64  |
| linux-arm64   | linux   | arm64   |
| macos-x64     | macos   | x86_64  |
| macos-arm64   | macos   | arm64   |
| windows-x64   | windows | x86_64  |

(`*-musl` suffixed entries fold into their non-musl row. Host-platform detection in `templates.bzl` additionally accepts `osx`/`aarch64` aliases.)

### pkgx Runtime Environment

The dispatcher composes env vars from `_PKGX_ENV_SUBDIRS` (only subdirs that exist in the extracted bottles, deps first / root last) plus each bottle's `pkgx_runtime_env` with `{{prefix}}` rewritten to the in-repo bottle path. It resolves its own location through symlinks, with a runfiles-tree fallback for remote execution where the `tool` output symlink may materialize as a plain file.

## Comparison with rules_multitool

`rules_mise` is similar to `rules_multitool` but with differences:

1. **Lockfile Format**: `rules_multitool` uses JSON, `rules_mise` uses TOML (`mise.lock`, parsed with `toml.bzl`).
2. **Tool Sources**: `rules_mise` consumes `mise.toml`-managed tools including aqua/npm/core backends and `pkgx:` pantry closures with transitive bottles.
3. **Architecture**: both use separate per-platform tool repos fronted by a toolchain hub; `rules_mise` additionally generates `:cwd` / `:workspace_root` wrappers and per-binary pkgx targets.

## Dependencies

- `toml.bzl` (0.3.0) — TOML parsing of `mise.lock`.
- `bazel_lib` — `bzl_library` targets.
- `platforms` — OS/CPU constraints + host-constraint mapping.
- `bazel_features` — feature-detects `download_has_headers_param`.
- `bazel_tools//tools/build_defs/repo:utils.bzl` — netrc auth helpers.
