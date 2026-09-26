"""End-to-end test for two conda-backend postgres majors side by side.

`mise.toml` requests two different major versions of `conda:postgresql`
(17.x and 18.x). The test starts both servers at the same time (each
`pg_ctl start` backgrounds its server), waits until both accept connections,
then verifies each one reports its own expected major version — via both the
`psql --version` client string and `SHOW server_version` from the live
server — and serves an independent round-trip query.
"""

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

# rules_mise exposes one tool repo per requested version, so each major gets
# its own wrapper dispatching to its own conda prefix's bin/.
VERSIONS = {
    "17": r.Rlocation(os.path.join(
        "mise/tools/conda_postgresql_17.7", "tool")),
    "18": r.Rlocation(os.path.join(
        "mise/tools/conda_postgresql_18.4", "tool")),
}

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


def wait_ready(tool, sockdir):
    deadline = time.time() + 60
    while True:
        ready = subprocess.run(
            pg([tool, "pg_isready", "-h", sockdir]),
            capture_output=True, text=True)
        if ready.returncode == 0:
            return
        if time.time() > deadline:
            print(ready.stdout)
            print(ready.stderr, file=sys.stderr)
            sys.exit("server never became ready")
        time.sleep(0.5)


# Unix socket paths are limited to ~107 chars, so keep everything under /tmp
# instead of the (potentially very deep) Bazel test tmpdir.
tmp = tempfile.mkdtemp(prefix="pg_multi_e2e_")
if DROP is not None:
    os.chown(tmp, user.pw_uid, user.pw_gid)
    os.environ["HOME"] = os.path.join(tmp, "home")
    os.mkdir(os.environ["HOME"])
    os.chown(os.environ["HOME"], user.pw_uid, user.pw_gid)

servers = {}
try:
    for major, tool in VERSIONS.items():
        pgdata = os.path.join(tmp, "data-%s" % major)
        sockdir = os.path.join(tmp, "sock-%s" % major)
        os.mkdir(sockdir)
        if DROP is not None:
            os.chown(sockdir, user.pw_uid, user.pw_gid)
        servers[major] = {"tool": tool, "pgdata": pgdata, "sockdir": sockdir}

    # The clients themselves work and link the conda openssl/readline closure.
    for major, server in servers.items():
        version = run([server["tool"], "psql", "--version"])
        assert "psql (PostgreSQL) %s." % major in version, (
            "unexpected version for %s: %r" % (major, version))

    # initdb both clusters, then start both servers so they run in the
    # background at the same time before verifying either of them.
    for major, server in servers.items():
        run(pg([server["tool"], "initdb", "-D", server["pgdata"],
                "-U", "postgres", "--auth=trust",
                "--no-locale", "-E", "UTF8"]))
    for major, server in servers.items():
        logfile = os.path.join(tmp, "server-%s.log" % major)
        run(pg([server["tool"], "pg_ctl", "-D", server["pgdata"],
                "-l", logfile, "-w", "-t", "60", "start",
                "-o", "-c listen_addresses='' -k %s" % server["sockdir"]]))
        server["started"] = True

    for major, server in servers.items():
        wait_ready(server["tool"], server["sockdir"])

    # Each live server must report its own expected major version, and each
    # must serve queries independently of the other.
    for major, server in servers.items():
        server_version = run(pg([server["tool"], "psql",
                                 "-h", server["sockdir"],
                                 "-U", "postgres", "-tAc",
                                 "SHOW server_version;"]))
        assert server_version.strip().startswith(major + "."), (
            "unexpected server_version for %s: %r" % (major, server_version))
        out = run(pg([server["tool"], "psql",
                      "-h", server["sockdir"], "-U", "postgres", "-tAc",
                      "CREATE TABLE t(a int);"
                      " INSERT INTO t VALUES (%s);"
                      " SELECT a FROM t;" % major]))
        assert out.strip().splitlines()[-1] == major, (
            "unexpected query result for %s: %r" % (major, out))
finally:
    for server in servers.values():
        if server.get("started"):
            subprocess.run(pg([server["tool"], "pg_ctl",
                               "-D", server["pgdata"], "-m", "fast", "stop"]),
                           capture_output=True, text=True)
    shutil.rmtree(tmp, ignore_errors=True)

print("psql multi-version end-to-end lifecycle OK")
