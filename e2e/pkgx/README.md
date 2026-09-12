# pkgx e2e

Exercises a `pkgx:`-backend tool (`pkgx:stedolan.github.io/jq`) from an
end-user's perspective: the lockfile records the main bottle plus transitive
`[pkgx-packages]` dependencies, and `rules_mise` installs the whole closure
and generates a launcher that sets the pantry runtime environment
(`LD_LIBRARY_PATH`, `PATH`, ...) like `mise` does.

The `pkgx` backend is experimental, hence `[settings] experimental = true` in
`mise.toml`.

## Why jq and not postgresql

This test originally targeted `pkgx:postgresql.org`, but `mise lock` cannot
resolve it (mise 2026.9.5, `0 platform entries, 7 skipped`):

```text
failed to resolve pkgx:postgresql.org for linux-x64:
  no pkgx version for openssl.org satisfies ^1.0.1
```

The pantry `postgresql.org/package.yml` depends on `openssl.org: ^1.0.1`,
and bottles `1.1.1s`–`1.1.1w` exist on `dist.pkgx.dev`, but mise's
`semver_satisfies` (`src/backend/pkgx.rs`) matches candidates with
`NodeVersion::parse`, which rejects the letter-suffixed `1.1.1w` versions,
leaving only `3.x` — none of which satisfy `^1`. The `pkgx` CLI resolves
the same closure fine. Until this is fixed upstream, the e2e uses
`pkgx:stedolan.github.io/jq`, whose closure (`oniguruma`) locks cleanly.
