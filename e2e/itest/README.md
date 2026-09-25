# itest e2e

Exercises the same `conda:postgresql` tool as `e2e/conda` plus
`conda:valkey-server`, but the server lifecycles are owned by
[rules_itest](https://github.com/hermeticbuild/rules_itest)
instead of the Python test binary:

- `postgres.bzl` builds a `pg_server` wrapper around the mise-provided
  conda `:tool` wrapper. On first start it runs `initdb` into
  `$TMPDIR/pgdata` (dropping root privileges via `setpriv`/`runuser` to
  `nobody`, since postgres refuses to run as root), then execs `postgres`.
  Extra service `args` (the autoassigned TCP port) are forwarded via `"$@"`.
- `itest_service(name = "postgres")` starts that wrapper on an autoassigned
  port with `pg_isready` (via the `:tool` wrapper's first-argument dispatch)
  as health check.
- `itest_service(name = "valkey")` runs `valkey-server` from
  `conda:valkey-server` directly on an autoassigned port (in-memory only:
  `--save '' --appendonly no`) with `valkey-cli ping` as health check.
- `service_test(name = "test_psql")` brings up both services, exports their
  ports as `PGPORT`/`VALKEYPORT`, and runs `test_psql_itest.py`, which only
  acts as a client: a `psql` `CREATE/INSERT/SELECT` round-trip asserting `42`
  plus a `valkey-cli` `PING`/`SET`/`GET` round-trip.

Run with:

```bash
cd e2e/itest && bazel test //:test_psql
```
