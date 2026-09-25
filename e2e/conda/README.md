# conda e2e

Exercises a `conda:`-backend tool (`conda:postgresql`) from an
end-user's perspective: the lockfile records the main package plus transitive
`[conda-packages]` dependencies, and `rules_mise` installs the whole closure
into a conda prefix and generates a launcher that sets the conda runtime
environment (`CONDA_PREFIX`, `PATH`, activation scripts) like `mise` does.

`test_psql.py` runs a full server lifecycle against the packaged binaries:
`initdb`, `pg_ctl start`, a `CREATE/INSERT/SELECT` round-trip through `psql`
over a Unix socket, then `pg_ctl stop`. All binaries are reached through the
single `@mise//tools/conda_postgresql:tool` wrapper, which dispatches on its
first argument (e.g. `tool psql --version`) and also supports `argv[0]`
dispatch for per-binary symlinks.

## Note on remote execution

Two things are needed to run this test on BuildBuddy's remote executors:

- The conda-forge builds need a modern glibc, while BuildBuddy's default
  execution platform is Ubuntu 16.04 (glibc 2.23), so the repo's `buildbuddy`
  configs set `container-image` to the Ubuntu 24.04 image from
  `buildbuddy-io/buildbuddy-toolchain` (`UBUNTU24_04_IMAGE`) as the default
  for all remote actions.
- Containers run as root and postgres refuses `initdb` as root, so the test
  drops privileges via `setpriv`/`runuser` to `nobody` when it starts as
  root (and `chown`s its scratch dirs accordingly).

Related `rules_mise` behavior worth knowing: conda packages (`.conda` files)
are zipped `tar.zst` archives. The tool repo extracts the outer zip with
Bazel's built-in zip support, then extracts the inner `pkg-*.tar.zst` with
Bazel's built-in `tar.zst` support (available in Bazel 8+), overlaying all
packages into a shared `conda-prefix/` layout. Prefix-placeholder replacement
is skipped: postgres binaries are relocatable via `$ORIGIN` RPATH and locate
their `share/` files relative to the binary, so they work when relocated.

## Note on regenerating `mise.lock`

`conda:postgresql@18.6` (latest at the time of writing) has no macOS builds
on conda-forge, so `mise lock` fails for `macos-arm64`/`macos-x64`. The
lockfile therefore pins `18.4`, which solves on all platforms
(`linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`, `windows-x64`).
