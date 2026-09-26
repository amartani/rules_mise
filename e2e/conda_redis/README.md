# conda_redis e2e

Exercises a `conda:`-backend tool (`conda:redis-server`) from an
end-user's perspective, mirroring `e2e/conda`: the lockfile records the
main package plus transitive `[conda-packages]` dependencies, and
`rules_mise` installs the whole closure into a conda prefix and generates
a launcher that sets the conda runtime environment (`CONDA_PREFIX`,
`PATH`, activation scripts) like `mise` does.

`test_redis.py` runs a full server lifecycle against the packaged
binaries: start `redis-server` on a free loopback port, wait for `PING`
via `redis-cli`, round-trip `SET e2e 42` / `GET e2e`, then `SHUTDOWN
NOSAVE`. Both binaries are reached through the single
`@mise//tools/conda_redis-server:tool` wrapper, which dispatches on its
first argument (e.g. `tool redis-server --version`) and also supports
`argv[0]` dispatch for per-binary symlinks.

## Why `7.2.4`

The lockfile pins `conda:redis-server@7.2.4` (rather than `latest`)
because its Linux closures pull in the `libgcc-ng` metapackage, which
ships no files: its `pkg-*.tar.zst` decompresses to an empty tar (which
Bazel's extractor rejects) and its `info/files` manifest is empty. That
is exactly the reported failure this test guards against: installing the
closure must skip the empty payload. Newer `redis-server` builds no
longer depend on `libgcc-ng`, so `latest` would not reproduce the issue.
`7.2.4` still solves on every Unix platform (`mise lock` skips only
`windows-x64`, which has no conda-forge `redis-server` build).
