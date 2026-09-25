"""End-to-end test against rules_itest-managed postgres and valkey.

The server lifecycles are owned by `itest_service` in BUILD; this binary is
only the client and performs a CREATE/INSERT/SELECT round-trip against
postgres plus a PING/SET/GET round-trip against valkey, both over TCP.
"""

import json
import os
import subprocess
import sys

from runfiles import Runfiles

r = Runfiles.Create()

PG_REPO = "mise/tools/conda_postgresql"
pg_tool = r.Rlocation(os.path.join(PG_REPO, "tool"))
psql = [pg_tool, "psql"]

VALKEY_REPO = "mise/tools/conda_valkey-server"
valkey_tool = r.Rlocation(os.path.join(VALKEY_REPO, "tool"))


def get_port(env_name, service_name, labels):
    port = os.environ.get(env_name)
    if not port:
        try:
            assigned = json.loads(os.environ.get("ASSIGNED_PORTS", "{}"))
        except json.JSONDecodeError:
            assigned = {}
        for key, value in assigned.items():
            if key.endswith(":%s" % service_name) or key.endswith(".%s" % service_name):
                port = value
                break
    if not port:
        get_port_bin = os.environ.get("GET_ASSIGNED_PORT_BIN")
        if get_port_bin:
            for label in labels:
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
        sys.exit("could not determine %s port (%s/ASSIGNED_PORTS unset)" % (service_name, env_name))
    return port


pgport = get_port("PGPORT", "postgres", ("@@//:postgres", "//:postgres"))
valkeyport = get_port("VALKEYPORT", "valkey", ("@@//:valkey", "//:valkey"))


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        sys.exit(result.returncode)
    return result.stdout


# The client itself works and links the conda openssl/readline closure.
version = run(psql + ["--version"])
assert "psql (PostgreSQL) 18." in version, "unexpected version: %r" % version

out = run(psql + [
    "-h", "127.0.0.1",
    "-p", pgport,
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


def valkey(*args):
    return run([valkey_tool, "valkey-cli", "-p", valkeyport] + list(args))


# The valkey server is up and serving: PING round-trips PONG.
pong = valkey("ping")
assert pong.strip() == "PONG", "unexpected ping reply: %r" % pong

# SET/GET round-trip through the conda valkey-cli against the service.
assert valkey("SET", "e2e", "42").strip() == "OK"
value = valkey("GET", "e2e")
assert value.strip() == "42", "unexpected valkey value: %r" % value

print("valkey itest lifecycle OK")
