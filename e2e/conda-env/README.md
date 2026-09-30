# conda env e2e

Exercises `mise.conda_env`, which installs several conda packages into **one**
conda prefix instead of one prefix per tool.

Each `conda:` entry in `mise.toml` is a separate mise tool, and `rules_mise`
gives every tool its own prefix. That works fine for standalone binaries, but
a PostgreSQL extension is only loadable by a server that shares its prefix:
`pgvector` installs `lib/vector.so` and `share/extension/vector.control`, and
`initdb` derives the server's extension directory from its own prefix. As two
separate tools, `CREATE EXTENSION vector` fails with `extension "vector" is
not available` no matter how both are added to a test's `data`.

So `MODULE.bazel` declares an environment instead:

```starlark
mise.conda_env(
    name = "pg",
    lockfile = "//:mise.lock",
    tools = [
        "conda:postgresql@18.4",
        "conda:pgvector@0.8.1",
    ],
)
```

`test_pgvector.py` starts a server out of `@mise//tools/conda_env_pg:tool`
(`initdb`, `pg_ctl start`, `psql`, `pg_ctl stop`, plus a readiness poll) and
then exercises pgvector through it: `CREATE EXTENSION vector`, a `vector(3)`
column, an `ORDER BY embedding <-> ...` nearest-neighbour query, and the
`<#>` and `<->` distance operators. An env is a tool like any other, so it
also gets `:cwd`, `:workspace_root` and a registered toolchain.

## Merging closures

Members' package closures are merged by conda package **name**, since one
environment holds exactly one build of each package. The two tools here
disagree on `libpq` (18.4 for `postgresql`, 18.6 for `pgvector`); installing
both would have them overwrite each other's files, so the highest version
wins — the choice conda's own solver converges on — and every dropped build
is reported:

```text
rules_mise: conda env 'pg' (linux_x86_64) installs libpq 18.6 instead of
libpq-18.4-hd5a49e9_1 (higher version)
```

A platform is only offered when *every* member has a build for it. An
environment missing one of its packages would install cleanly and then fail at
runtime, which is worse than not offering the target at all.

## Note on remote execution

Same two requirements as `../conda`, both handled in `pg_test_lib.py`: the
`buildbuddy` config pins the Ubuntu 24.04 image (the conda-forge builds need a
newer glibc than BuildBuddy's default Ubuntu 16.04 platform), and the test
drops privileges via `setpriv`/`runuser` because containers run as root and
postgres refuses `initdb` as root.
