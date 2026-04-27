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

## External Library Documentation

When working with external libraries, use the `context7` MCP to access up-to-date documentation:

- Bazel: `/bazelbuild/bazel`
- rules_multitool: `/bazel-contrib/rules_multitool`
- bazel_skylib: `/bazelbuild/bazel-skylib`
- bazel_lib: `/bazel-contrib/bazel-lib`

## Adding New Modules

When adding new modules, verify the current version in the [Bazel Central Registry](https://github.com/bazelbuild/bazel-central-registry) to ensure using an up-to-date version.
