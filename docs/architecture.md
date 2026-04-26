# rules_mise Architecture

## Overview

`rules_mise` is a Bazel module that allows using tools from [mise](https://mise.jdx.dev/) directly in Bazel BUILD files. It parses the `mise.lock` file to discover tool versions and their download URLs, then makes those tools available as Bazel targets.

## Core Concepts

### 1. Lockfile Format

The `mise.lock` file is a TOML file that contains tool definitions. Example:

```toml
[[tools.ruff]]
version = "0.15.11"
backend = "aqua:astral-sh/ruff"

[tools.ruff."platforms.linux-x64"]
url = "https://github.com/astral-sh/ruff/releases/download/0.15.11/ruff-x86_64-unknown-linux-musl.tar.gz"
checksum = "sha256:ea286f17b66054a3aac2672158b9ac194030d89043ff108357edd9b20123219a"
```

Key aspects:

- Tools are defined with `[[tools.<name>]]` (array of tables)
- Each tool has a `version`, `backend`, and platform-specific entries
- Platform keys follow the pattern `platforms.<os>-<arch>` (e.g., `linux-x64`, `macos-arm64`)

### 2. Module Extension

The module extension (`mise/extensions.bzl`) provides the entry point for users. It accepts a `hub` tag that specifies:

- `lockfile`: The path to `mise.lock`
- `hub_name`: Optional name for the hub repository (defaults to "mise")

```python
mise = use_extension("@rules_mise//mise:extensions.bzl", "mise")
mise.hub(lockfile = "//:mise.lock")
use_repo(mise, "mise")
```

### 3. Hub Repository

The hub repository (`mise/hub.bzl`) is the central repository that:

1. Parses the lockfile content
2. Downloads tool binaries for matching platforms (filters to linux-x64 for simplicity)
3. Generates BUILD files exposing tool targets

The hub creates:

- `tools/<tool_name>/BUILD.bazel` - Defines the tool target with filegroup
- `tools/<tool_name>/executable` - The downloaded binary
- `tools/BUILD.bazel` - Tool directory listing

### 4. Tool Usage

Tools are accessed via filegroup targets. The hub exposes a `tool` target for each tool:

```
@mise//tools/ruff:tool -> the ruff executable
```

**Note**: The current implementation filters to `linux-x64` platform only for simplicity. ARM64 and other platforms will be added in future versions.

## File Structure

```
mise/
├── BUILD.bazel              # Exports bzl_library targets
├── extensions.bzl         # Module extension implementation
├── hub.bzl                # Hub repository rule
└── private/
    ├── BUILD.bazel
    └── lockfile.bzl       # TOML parsing utilities
```

## Data Flow

1. **User Configuration** (MODULE.bazel)

   - User specifies `mise.hub(lockfile = "//:mise.lock")`
   - Bazel invokes the module extension

2. **Extension Execution** (extensions.bzl)

   - Reads lockfile labels
   - Calls `bzlmod_hub()` to create hub

3. **Hub Creation** (hub.bzl)

   - Module extension reads lockfile content using `module_ctx.read()`
   - Parses TOML to extract tool definitions
   - Creates repository rule `_mise_hub` with lockfile content as attribute

4. **Repository Rule Execution** (\_mise_hub_impl)

   - Parses TOML lockfile content
   - For each tool and platform:
     - Downloads binary from URL
     - Verifies SHA256 checksum
     - Extracts archive and copies executable
     - Generates BUILD file with filegroup

5. **Build Usage**
   - User references `@mise//tools/<tool>:tool` in BUILD files
   - Bazel resolves to the downloaded executable

## Key Implementation Details

### TOML Parsing

The lockfile is parsed using `toml.bzl` from the Bazel Central Registry:

```python
parsed = toml.decode(content)
tools_dict = parsed.get("tools", {})
```

### Platform Mapping

Mise platform names are mapped to Bazel constraints:

| Mise Platform | Bazel OS               | Bazel CPU               |
| ------------- | ---------------------- | ----------------------- |
| linux-x64     | @platforms//os:linux   | @platforms//cpu:x86_64  |
| linux-arm64   | @platforms//os:linux   | @platforms//cpu:aarch64 |
| macos-x64     | @platforms//os:osx     | @platforms//cpu:x86_64  |
| macos-arm64   | @platforms//os:osx     | @platforms//cpu:aarch64 |
| windows-x64   | @platforms//os:windows | @platforms//cpu:x86_64  |

### Archive Handling

Tools may be distributed as archives (`.tar.gz`, `.zip`). The hub handles extraction:

```python
if is_archive:
    rctx.download_and_extract(url = url, sha256 = checksum, output = "tools/{}".format(name))
    # Find and copy the executable from extracted archive
    result = rctx.execute(["find", extract_dir, "-name", "ruff*", "-type", "f"])
    if lines:
        rctx.execute(["cp", src, output])
        rctx.execute(["chmod", "+x", output])
```

## Comparison with rules_multitool

`rules_mise` is similar to `rules_multitool` but with differences:

1. **Lockfile Format**: `rules_multitool` uses JSON, `rules_mise` uses TOML
2. **Tool Resolution**: `rules_multitool` uses complex toolchain resolution; `rules_mise` currently uses simpler filegroup targets
3. **Architecture**: `rules_multitool` has separate tool repos per platform; `rules_mise` downloads all platforms in the hub

## Future Improvements

1. **Multi-platform Support**: Add proper toolchain-based resolution for all platforms (linux-arm64, macos-x64, macos-arm64, windows-x64)
2. **mise Tool Integration**: Add support for using mise itself to install tools
3. **Multiple Lockfiles**: Support merging multiple lockfiles from different modules
4. **Version Resolution**: Add semantic version-aware version selection

## Dependencies

- `toml.bzl` (0.3.0) - TOML parsing
- `bazel_lib` - Utilities for bzl_library targets
- `platforms` - OS/CPU constraint definitions
