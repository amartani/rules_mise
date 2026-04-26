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

- **bzlmod-only**: No WORKSPACE legacy mode
- **Core files**: `mise/hub.bzl` (filegroup provider), `mise/extensions.bzl` (module extension), `mise/toml.bzl` (TOML parser)
- **E2E test**: `e2e/smoke/` - verifies build works with mise tools via filegroup

## Repo Structure

See @docs/architecture.md
