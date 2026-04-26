# AGENTS.md

## Key Commands

```bash
# Build and test
bazel build //...
bazel test //...

# E2E test (in subdirectory)
cd e2e/smoke && bazel build //:ruff_check
```

## Architecture

- **bzlmod-only**: No WORKSPACElegacy mode
- **Core files**: `mise/hub.bzl` (filegroup provider), `mise/extensions.bzl` (module extension), `mise/toml.bzl` (TOML parser)
- **E2E test**: `e2e/smoke/` - verifies build works with mise tools via filegroup

## Repo Structure

```
mise/           # Core rules (hub, extensions)
mise/private/   # Implementation (lockfile parsing)
e2e/smoke/      # Integration test
docs/           # Documentation
tools/          # Helper tools
```

## Pre-commit Hooks

Required before commit: `prek` (buildifier, buildifier-lint, prettier, yamlfmt, typos, commitizen)
mise/ # Core rules (hub, extensions)
mise/private/ # Implementation (lockfile parsing)
e2e/smoke/ # Integration test
docs/ # Documentation
tools/ # Helper tools

```

```
