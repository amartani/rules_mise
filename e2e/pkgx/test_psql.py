"""End-to-end test for a pkgx-backend postgres: initdb, start, query, stop."""

import os
import shutil
import subprocess
import sys
import tempfile
import time

from runfiles import Runfiles

r = Runfiles.Create()

REPO = "mise/tools/pkgx_postgresql.org"
psql = r.Rlocation(os.path.join(REPO, "psql"))
initdb = r.Rlocation(os.path.join(REPO, "initdb"))
pg_ctl = r.Rlocation(os.path.join(REPO, "pg_ctl"))
pg_isready = r.Rlocation(os.path.join(REPO, "pg_isready"))


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

# Unix socket paths are limited to ~107 chars, so keep everything under /tmp
# instead of the (potentially very deep) Bazel test tmpdir.
tmp = tempfile.mkdtemp(prefix="pg_e2e_")
pgdata = os.path.join(tmp, "data")
sockdir = os.path.join(tmp, "sock")
os.mkdir(sockdir)
started = False
try:
    run([initdb, "-D", pgdata, "-U", "postgres", "--auth=trust",
         "--no-locale", "-E", "UTF8"])
    logfile = os.path.join(tmp, "server.log")
    run([pg_ctl, "-D", pgdata, "-l", logfile, "-w", "-t", "60", "start",
         "-o", "-c listen_addresses='' -k %s" % sockdir])
    started = True

    deadline = time.time() + 60
    while True:
        ready = subprocess.run(
            [pg_isready, "-h", sockdir], capture_output=True, text=True)
        if ready.returncode == 0:
            break
        if time.time() > deadline:
            print(ready.stdout)
            print(ready.stderr, file=sys.stderr)
            sys.exit("server never became ready")
        time.sleep(0.5)

    out = run([psql, "-h", sockdir, "-U", "postgres", "-tAc",
               "CREATE TABLE t(a int);"
               " INSERT INTO t VALUES (42);"
               " SELECT a FROM t;"])
    assert out.strip().splitlines()[-1] == "42", (
        "unexpected query result: %r" % out
    )
finally:
    if started:
        subprocess.run([pg_ctl, "-D", pgdata, "-m", "fast", "stop"],
                       capture_output=True, text=True)
    shutil.rmtree(tmp, ignore_errors=True)

print("psql end-to-end lifecycle OK")
