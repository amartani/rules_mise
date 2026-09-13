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

## Note on remote execution

Two things are needed to run this test on BuildBuddy's remote executors:

- The `pkgx` bottles are built against a modern glibc (>= 2.25) while the
  default execution platform is Ubuntu 16.04 (glibc 2.23), so `test_psql`
  carries `exec_properties = {"container-image": "docker://ubuntu:22.04"}`.
- Containers run as root and postgres refuses `initdb` as root, so the test
  drops privileges via `setpriv`/`runuser` to `nobody` when it starts as
  root (and `chown`s its scratch dirs accordingly).

Related `rules_mise` behavior worth knowing: the per-binary launchers are
symlinks to the shared dispatcher, and remote execution may materialize
them as plain files. The dispatcher therefore falls back to locating the
bottles via the runfiles root plus the tool repo's runfiles path when they
are not next to the script itself (see `mise/hub.bzl`).

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
