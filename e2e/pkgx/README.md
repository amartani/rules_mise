# pkgx e2e

Exercises a `pkgx:`-backend tool (`pkgx:postgresql.org`) from an
end-user's perspective: the lockfile records the main bottle plus transitive
`[pkgx-packages]` dependencies, and `rules_mise` installs the whole closure
and generates a launcher that sets the pantry runtime environment
(`LD_LIBRARY_PATH`, `PATH`, ...) like `mise` does.

The `pkgx` backend is experimental, hence `[settings] experimental = true` in
`mise.toml`.

`test_psql.py` runs a full server lifecycle against the packaged binaries:
`initdb`, `pg_ctl start`, a `CREATE/INSERT/SELECT` round-trip through `psql`
over a Unix socket, then `pg_ctl stop`.

## Note on regenerating `mise.lock`

`mise lock` could not resolve `pkgx:postgresql.org` before mise 2026.9.6:
the pantry package depends on `openssl.org: ^1.0.1`, but mise's
`NodeVersion`-based matcher rejected the letter-suffixed `1.1.1w` bottles on
`dist.pkgx.dev`, leaving only `3.x` (`no pkgx version for openssl.org
satisfies ^1.0.1`, 7/7 platforms skipped). Upstream fixed this by matching
with `libsemverator` plus coercion of trailing-letter versions
(`refactor(pkgx): use libsemverator for version comparison`). Regenerating
this lockfile therefore requires a mise containing that fix; `rules_mise`
itself only reads the lockfile.
