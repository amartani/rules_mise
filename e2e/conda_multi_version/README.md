# conda_multi_version e2e

Exercises **two major versions** of a `conda:`-backend tool from one
`mise.toml`:

```toml
[tools]
"conda:postgresql" = ["17.7", "18.4"]
```

`mise lock` records one `[[tools."conda:postgresql"]]` entry per version, and
`rules_mise` exposes one tool repo per version
(`@mise//tools/conda_postgresql_17.7:tool` and
`@mise//tools/conda_postgresql_18.4:tool`).

`test_psql_multi.py` starts both servers at the same time (each `pg_ctl
start` backgrounds its server), waits until both accept connections, then
verifies each one reports its own expected major version — via both `psql
--version` and `SHOW server_version` from the live server — and serves an
independent round-trip query, before stopping both.

See `../conda/README.md` for the notes on remote execution (Ubuntu 24.04
container image, dropping root privileges) and on relocatable conda
postgres builds; they apply here unchanged.
