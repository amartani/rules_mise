"""End-to-end test for a pkgx-backend postgres: initdb, start, query, stop."""

import grp
import os
import pwd
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

# postgres refuses to run as root, and remote-execution containers run as
# root, so drop privileges for the server tools when we start out as root.
# The action PATH may not include /usr/sbin, so probe absolute locations too.
DROP = None
if os.geteuid() == 0:
    user = pwd.getpwnam("nobody")
    try:
        group = grp.getgrgid(user.pw_gid).gr_name
    except KeyError:
        group = "nogroup"
    candidates = [
        ["setpriv", "--reuid=%s" % user.pw_name, "--regid=%s" % group,
         "--clear-groups"],
        ["runuser", "-u", user.pw_name, "--"],
    ]
    for cand in candidates:
        path = shutil.which(cand[0])
        if path is None:
            for directory in ("/usr/bin", "/usr/sbin", "/sbin", "/bin"):
                full = os.path.join(directory, cand[0])
                if os.path.exists(full):
                    path = full
                    break
        if path is not None:
            DROP = [path] + cand[1:]
            break
    if DROP is None:
        sys.exit("running as root without setpriv/runuser to drop privileges")


def pg(args):
    if DROP is None:
        return args
    return DROP + args


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
if DROP is not None:
    # Directories created above belong to root; hand them to the
    # unprivileged user and give it a writable HOME for good measure.
    os.chown(tmp, user.pw_uid, user.pw_gid)
    os.chown(sockdir, user.pw_uid, user.pw_gid)
    os.environ["HOME"] = sockdir
started = False
try:
    run(pg([initdb, "-D", pgdata, "-U", "postgres", "--auth=trust",
            "--no-locale", "-E", "UTF8"]))
    logfile = os.path.join(tmp, "server.log")
    run(pg([pg_ctl, "-D", pgdata, "-l", logfile, "-w", "-t", "60", "start",
            "-o", "-c listen_addresses='' -k %s" % sockdir]))
    started = True

    deadline = time.time() + 60
    while True:
        ready = subprocess.run(
            pg([pg_isready, "-h", sockdir]), capture_output=True, text=True)
        if ready.returncode == 0:
            break
        if time.time() > deadline:
            print(ready.stdout)
            print(ready.stderr, file=sys.stderr)
            sys.exit("server never became ready")
        time.sleep(0.5)

    out = run(pg([psql, "-h", sockdir, "-U", "postgres", "-tAc",
                  "CREATE TABLE t(a int);"
                  " INSERT INTO t VALUES (42);"
                  " SELECT a FROM t;"]))
    assert out.strip().splitlines()[-1] == "42", (
        "unexpected query result: %r" % out
    )
finally:
    if started:
        subprocess.run(pg([pg_ctl, "-D", pgdata, "-m", "fast", "stop"]),
                       capture_output=True, text=True)
    shutil.rmtree(tmp, ignore_errors=True)

print("psql end-to-end lifecycle OK")
