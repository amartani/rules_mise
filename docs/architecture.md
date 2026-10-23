# rules_mise Architecture

## Overview

`rules_mise` is a Bazel module that allows using tools from
[mise](https://mise.jdx.dev/) directly in Bazel BUILD files. It parses the
`mise.lock` file to discover tool versions and their download URLs, then makes
those tools available as Bazel targets behind toolchain resolution.

## Core Concepts

### 1. Lockfile Format

The `mise.lock` file is a `@generated` TOML file (bump versions in `mise.toml`,
don't hand-edit). Example:

```toml
[[tools.ruff]]
version = "0.16.7"
backend = "aqua:astral-sh/ruff"

[tools.ruff."platforms.linux-x64"]
url = "https://github.com/astral-sh/ruff/releases/download/0.16.7/ruff-x86_64-unknown-linux-musl.tar.gz"
checksum = "sha256:8d28939cf5cabe54a2f8f7cbfab52c643436d1bc70474198181db9e48f504411"
```

Key aspects (see `mise/private/lockfile.bzl`):

- Tools are `[[tools.<name>]]` (array of tables) or a single `[tools.<name>]`
  table; each entry has `version`, `backend`, and `platforms.<os>-<arch>`
  subtables. Entries are grouped by `version` (so one entry per version), and
  each group carries the first entry's `version`/`backend`.
- Recognized platforms: `linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`,
  `windows-x64`. `linux-*-musl` entries are ignored (folded into the non-musl
  entry); anything else is skipped.
- Entries without a usable `url` are skipped, as are single-file-compressed
  assets (`.gz`/`.bz2`/`.xz`/`.zst` — lone compressed binaries that Bazel
  cannot extract). A `sha256:`-prefixed `checksum` is verified; a checksum in
  any other format (e.g. mise's `blake3:`), or no checksum at all, leaves the
  download unverified and marks the tool repo non-reproducible. Tools left with
  no supported platform entries are skipped with a warning.
- Tool names are sanitized for Bazel (`_clean`): only `:`, `/`, `+`, `@`, and
  space become `_`; `-` and `.` are kept (e.g. `npm:prettier` → `npm_prettier`).
  The trailing name segment is also kept as an executable-discovery hint
  (`hint`) for archives whose binary omits the backend prefix.
- A tool requested at multiple versions
  (`"conda:postgresql" = ["17.7", "18.4"]`, one `[[tools.<name>]]` entry per
  version) becomes one Bazel tool per version, keyed by
  `_clean(<name>@<version>)` (e.g. `conda_postgresql_17.7`); single-version
  tools keep the legacy `_clean(<name>)` key. Entries sharing a version stay
  merged.
- conda tools (`backend = "conda:..."`) additionally carry `conda_deps` per
  platform, resolved against a shared `[conda-packages.<platform>]` lockfile
  section. Only `bin/` and `sbin/` provides become Bazel targets via the
  dispatcher (currently a single `:tool` wrapper dispatching on its first
  argument and on `argv[0]`).

### 2. Module Extension

The module extension (`mise/extensions.bzl`) provides the entry point. It
accepts two tags:

- `hub`: parses a `mise.lock` into a hub repository.
  - `lockfile`: label of a `mise.lock` file (mandatory, single file).
  - `hub_name`: name of the hub repository (defaults to `"mise"`).
- `conda_env`: exposes several conda tools merged into one prefix (see below).
  - `name`: environment name; the tool is keyed `conda_env_<name>`.
  - `lockfile`: label of the `mise.lock` used to resolve `tools`.
  - `tools`: mise tool names with optional `@version` suffixes.

```python
mise = use_extension("@rules_mise//mise:extensions.bzl", "mise")
mise.hub(lockfile = "//:mise.lock")
mise.conda_env(
    name = "pg",
    lockfile = "//:mise.lock",
    tools = ["conda:postgresql@18.4", "conda:pgvector@0.8.1"],
)
use_repo(mise, "mise")

register_toolchains("@mise//toolchains:all")
```

The extension collects lockfiles per `hub_name` across modules (a hub may be
fed by several lockfiles), while `conda_env` entries are collected per
lockfile label and attached to every hub reading the same lockfile. Hub names
declared by the root module are reported as direct (or dev) deps, and the
extension reports `reproducible = True` metadata.

### 3. Per-Platform Tool Repositories

`bzlmod_hub()` (`mise/hub.bzl`) creates one `tool_repo` per tool per platform,
named `{hub}.{tool}.{os}_{cpu}` (e.g. `mise.ruff.linux_x86_64`). Each downloads
and prepares its own binary:

- `kind = "file"`: `rctx.download()` straight to
  `tools/<tool>/<os>_<cpu>_executable[.exe]`.
- `kind = "archive"` (`.tar.gz`, `.tgz`, `.tar.xz`, `.tar.bz2`, `.tar`, `.zip`):
  `download_and_extract`, then locate the executable — an explicit `file` path
  when the tool entry declares one, otherwise the best basename match: patterns
  try the `hint` (the trailing segment of a backend-prefixed name) before the
  tool name, in `-`/`_` variants, ranked as exact match (with the platform
  `.exe` extension), prefix match with no file extension in the remainder
  (native binaries conventionally have none), then any prefix match. With no
  match at all, the first file in sorted order is used.
- `kind = "pkg"` (macOS installer packages): expanded with
  `pkgutil --expand-full` (macOS-only; requires `pkgutil`, marked
  non-reproducible).
- conda tools: every package in the closure (transitive deps first, root last)
  is extracted under `tools/<tool>/conda-prefix/`, reproducing mise's install
  layout (`.conda` outer zip via `extract` as `zip`, then inner `pkg-*.tar.zst`
  via `extract` as `tar.zst`; `.tar.bz2` direct). Packages whose file manifest
  names no files (empty metapackages such as conda-forge's `libgcc-ng`, or
  `fonts-conda-forge-1`, which rattler-build builds with `info/paths.json` and
  no `info/files` at all) contribute nothing to the prefix, so their payload is
  skipped — Bazel's extractor rejects empty tars. Both manifest layouts are
  read, since either may be the only one present. A generated bash dispatcher
  (`<os>_<cpu>_executable`) sets the conda runtime environment (`CONDA_PREFIX`,
  `PATH`, activation scripts) and dispatches on `argv[0]` (for per-binary
  symlinks) or on its first argument (so a single `:tool` can run any `bin/`
  binary, e.g. `tool psql --version`).
  Windows conda is unsupported and fails fast.

Downloads honor private registries via netrc (`NETRC` env / user netrc matched
against per-URL auth patterns), and forward `headers` on Bazel versions that
support `download_has_headers_param`. Extracted conda file lists are enumerated
explicitly (files + symlinks, never directories); symlink cycles are dropped
since neither globs nor runfiles trees can traverse them.

### 4. Hub Repository

The `_mise_hub` repository itself contains no binaries — it declares toolchains
and the user-facing rules:

- `toolchain_info.bzl` — `toolchain_info` rule (`executable`, `os`, `cpu`,
  `ext`, `files`) plus `declare_toolchain()`, which wires each `tool_repo`
  executable into `exec` + `target` toolchains constrained on
  `@platforms//os:{os}` / `@platforms//cpu:{cpu}`.
- `toolchains/BUILD.bazel` — calls every tool's `declare_toolchains()`. Users
  register them with `register_toolchains("@mise//toolchains:all")`.
- `tools/<tool>/tool.bzl` — a `tool` rule that resolves
  `//tools/<tool>:toolchain_type` and symlinks the selected toolchain executable
  to its own output (plus runfiles, so conda closures travel with it).
- `tools/<tool>/BUILD.bazel` — `toolchain_type`, `:tool`, plus `:cwd` and
  `:workspace_root` wrappers (below).
- `tools.bzl` — `TOOLS` label map + `register_tools()` for non-bzlmod
  `WORKSPACE` usage (`workspace_hub()` path).

### 5. Tool Usage

Tools resolve through the toolchain, so the same label picks the right binary
per execution platform:

```text
@mise//tools/ruff:tool -> ruff for the current platform
@mise//tools/ruff:cwd -> wrapper running ruff with $PWD = Bazel's cwd
@mise//tools/ruff:workspace_root -> ruff with $BUILD_WORKSPACE_DIRECTORY as cwd
@mise//tools/conda_postgresql:tool -> conda wrapper for prefix bin/ binaries
@mise//tools/conda_postgresql_17.7:tool -> same, for the 17.7 install
```

`:cwd` / `:workspace_root` (`mise/private/run_in.bzl`) expand a small wrapper
script (`.sh`, or `.bat` for `.exe` tools) that `cd`s into `$PWD` /
`$BUILD_WORKSPACE_DIRECTORY` and execs the resolved tool. The wrapper locates
the tool next to itself first (works under `bazel run`, direct execution, and in
the runfiles tree), then via `$RUNFILES_DIR` / the runfiles manifest, and
finally via the legacy `$PWD`-relative short path.

## File Structure

```text
mise/
├── BUILD.bazel              # bzl_library targets: extensions, hub, cwd, workspace_root
├── extensions.bzl           # module extension (hub tag -> bzlmod_hub)
├── hub.bzl                  # bzlmod_hub / workspace_hub + tool_repo
├── cwd.bzl / workspace_root.bzl  # public re-exports of the private wrappers
└── private/
    ├── lockfile.bzl         # mise.lock parsing, conda payloads
    ├── templates.bzl        # hub/tools.bzl rendering, host-constraint mapping
    ├── run_in.bzl           # shared cwd/workspace_root wrapper implementation
    ├── cwd.bzl / workspace_root.bzl
    ├── run_in.template.sh / run_in.template.bat
    ├── hub_repo_template/   # BUILD/toolchain shells
    └── hub_repo_tool_template/  # per-tool tool.bzl / BUILD shells (used by hub.bzl)
```

## Data Flow

1. **User configuration** (`MODULE.bazel`):
   `mise.hub(lockfile = "//:mise.lock")`, `use_repo(mise, "mise")`,
   `register_toolchains("@mise//toolchains:all")`.
2. **Extension execution** (`extensions.bzl`): gathers lockfile labels per hub,
   collects `conda_env` declarations per lockfile, and calls
   `bzlmod_hub(name, lockfiles, module_ctx, envs)`.
3. **Tool repo creation** (`bzlmod_hub`): parses the lockfiles via
   `lockfile.load_defs()`, instantiates one `tool_repo` per binary (JSON-encoded
   binary descriptor), then creates `_mise_hub` with the lockfile labels.
4. **Repository fetching** (`tool_repo` impl): downloads/verifies/extracts per
   §3; conda repos additionally write the dispatcher and an explicit-srcs
   `conda_files` filegroup.
5. **Hub generation** (`_mise_hub_impl`): renders `toolchain_info.bzl`,
   root/tool `BUILD` files, per-tool `tool.bzl` + `BUILD.bazel`,
   `toolchains/BUILD.bazel`, and `tools.bzl`.
6. **Build usage**: `@mise//tools/<tool>:tool` resolves through the registered
   toolchain for the execution platform.

## Key Implementation Details

### Platform Mapping

Mise platform suffixes map to toolchain `os`/`cpu` strings, which become
`@platforms//os:{os}` / `@platforms//cpu:{cpu}` constraints:

| Mise Platform | os      | cpu    |
| ------------- | ------- | ------ |
| linux-x64     | linux   | x86_64 |
| linux-arm64   | linux   | arm64  |
| macos-x64     | macos   | x86_64 |
| macos-arm64   | macos   | arm64  |
| windows-x64   | windows | x86_64 |

(`*-musl` suffixed entries fold into their non-musl row. Host-platform detection
in `templates.bzl` additionally accepts `osx`/`aarch64` aliases.)

### conda Runtime Environment

The dispatcher composes env vars like mise's conda launcher:
`CONDA_PREFIX`/`CONDA_DEFAULT_ENV`/`CONDA_SHLVL`, `PATH` with the prefix's
`bin/` and `sbin/` first, plus sourcing `etc/conda/activate.d/*.sh`. It resolves
its own location through symlinks, with a runfiles-tree fallback (directory
walk plus `$RUNFILES_MANIFEST_FILE` lookup, mirroring `run_in`) for remote
execution where the `tool` output symlink may materialize as a plain file.
It fails loudly when no layout resolves, warns when the resolved prefix
contains no symlinks near the top (a dereferenced input tree symptom), and
accepts `--rules-mise-conda-prefix` to print the resolved prefix without
execing a binary.

Two path hazards apply to every conda prefix and are easy to misdiagnose
(see [conda-prefix-paths.md](conda-prefix-paths.md) for the full analysis):

- The runfiles tree assumes a symlink forest that remote execution does not
  preserve: file-type artifacts upload as regular files even when they are
  symlinks on disk, so self-locating binaries (symlink `$0` walks) break in
  confusing ways. `e2e/conda_opensearch` works around this by copying the
  distribution into a scratch dir.
- Bzlmod canonical repository names contain `+` (`<module>++<ext>+<repo>`),
  so any tool that parses its own path as a URL (e.g. OpenSearch's
  `URLDecoder.decode()` on policy files) breaks on remote executors, where
  the path is materialized, while accidentally passing locally via the
  `+`-free repository cache.

Build-prefix placeholders from each package's `info/has_prefix` are replaced at
fetch time with a short stable prefix (`/tmp/mise_conda_<hash>`), text by plain
replacement and binaries null-padded so sizes are preserved; the dispatcher
symlinks that stable prefix to the real `CONDA_PREFIX` at runtime, since only
then is the real path known. Without this, postgres cannot find its tzdata,
whose `--with-system-tzdata` path is baked in as an absolute build-prefix path.

See [conda-prefix-paths.md](conda-prefix-paths.md) for the path hazards that
the runfiles fallback implies (symlink dereferencing, and `+` in canonical repo
names) and the proposed fixes.

## Comparison with rules_multitool

`rules_mise` is similar to `rules_multitool` but with differences:

1. **Lockfile Format**: `rules_multitool` uses JSON, `rules_mise` uses TOML
   (`mise.lock`, parsed with `toml.bzl`).
2. **Tool Sources**: `rules_mise` consumes `mise.toml`-managed tools including
   aqua/npm/core backends and `conda:` prefixes with transitive closures.
3. **Architecture**: both use separate per-platform tool repos fronted by a
   toolchain hub; `rules_mise` additionally generates `:cwd` / `:workspace_root`
   wrappers and a conda dispatcher.

## Dependencies

- `toml.bzl` (0.3.0) — TOML parsing of `mise.lock`.
- `bazel_lib` — `bzl_library` targets.
- `platforms` — OS/CPU constraints + host-constraint mapping.
- `bazel_features` — feature-detects `download_has_headers_param`.
- `bazel_tools//tools/build_defs/repo:utils.bzl` — netrc auth helpers.
