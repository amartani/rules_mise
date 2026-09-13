"""End-to-end test against a rules_itest-managed postgres.

The server lifecycle (initdb + postgres + health check) is owned by
`itest_service` in BUILD; this binary is only the client and performs the
same CREATE/INSERT/SELECT round-trip as e2e/pkgx over TCP.
"""

import json
import os
import subprocess
import sys

from runfiles import Runfiles

r = Runfiles.Create()

REPO = "mise/tools/pkgx_postgresql.org"
psql = r.Rlocation(os.path.join(REPO, "psql"))

port = os.environ.get("PGPORT")
if not port:
    try:
        assigned = json.loads(os.environ.get("ASSIGNED_PORTS", "{}"))
    except json.JSONDecodeError:
        assigned = {}
    for key, value in assigned.items():
        if key.endswith(":postgres") or key.endswith(".postgres"):
            port = value
            break
if not port:
    get_port_bin = os.environ.get("GET_ASSIGNED_PORT_BIN")
    if get_port_bin:
        for label in ("@@//:postgres", "//:postgres"):
            try:
                out = subprocess.run(
                    [get_port_bin, label],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                if out.stdout.strip():
                    port = out.stdout.strip()
                    break
            except subprocess.CalledProcessError:
                continue
if not port:
    sys.exit("could not determine postgres port (PGPORT/ASSIGNED_PORTS unset)")


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        sys.exit(result.returncode)
    return result.stdout


# The client itself works and links the pkgx openssl/readline closure.
version = run([psql, "--version"])
assert "psql (PostgreSQL) 18." in version, "unexpected version: %r" % version

out = run([
    psql,
    "-h", "127.0.0.1",
    "-p", port,
    "-U", "postgres",
    "-tAc",
    "CREATE TABLE t(a int);"
    " INSERT INTO t VALUES (42);"
    " SELECT a FROM t;",
])
assert out.strip().splitlines()[-1] == "42", (
    "unexpected query result: %r" % out
)

print("psql itest lifecycle OK")
