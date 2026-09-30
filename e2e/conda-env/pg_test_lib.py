"""Shared helpers for the conda-env end-to-end tests.

Kept in one place so each test file only contains its own assertions. The
conda backend does not support Windows (see `mise/hub.bzl`), so these helpers
assume a POSIX environment.
"""

import grp
import os
import pwd
import shutil
import subprocess
import sys
import time

from runfiles import Runfiles

R = Runfiles.Create()

# Runfiles external repos live at <workspace>/<repo name>; a conda env is a
# tool of the mise hub repository, keyed `conda_env_<name>`.
HUB_REPO = "mise"


def env_tool(env):
    """Returns the path of the conda-env dispatcher wrapper for `env`."""
    path = R.Rlocation(os.path.join(HUB_REPO, "tools", "conda_env_" + env, "tool"))
    if not path:
        sys.exit("conda env tool not found in runfiles: %s/tools/conda_env_%s/tool" % (HUB_REPO, env))
    return path


def tool_name(env, binary):
    """Returns the argv prefix that runs `binary` from the `env` conda prefix."""
    return [env_tool(env), binary]


def _nobody():
    user = pwd.getpwnam("nobody")
    try:
        group = grp.getgrgid(user.pw_gid).gr_name
    except KeyError:
        group = "nogroup"
    return user, group


def drop_privileges():
    """Returns `(prefix, user)` for invoking postgres as a non-root user.

    postgres refuses to run as root and remote-execution containers run as
    root, so the server tools have to be invoked as an unprivileged user. The
    action PATH may not include /usr/sbin, so absolute locations are probed
    too. `prefix` is empty (and `user` is None) when already unprivileged.
    """
    if os.geteuid() != 0:
        return [], None
    user, group = _nobody()
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
            return [path] + cand[1:], user
    sys.exit("running as root without setpriv/runuser to drop privileges")


def as_postgres(args, drop):
    return drop + args


def chown_tree(path, user):
    """Hands `path` (and everything under it) to `user`."""
    if user is None:
        return
    os.chown(path, user.pw_uid, user.pw_gid)
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            full = os.path.join(root, name)
            if not os.path.islink(full):
                os.chown(full, user.pw_uid, user.pw_gid)


def wait_ready(probe, timeout=60):
    """Polls `probe` (an argv list) until it exits 0 or `timeout` elapses."""
    deadline = time.time() + timeout
    while True:
        result = subprocess.run(probe, capture_output=True, text=True)
        if result.returncode == 0:
            return
        if time.time() > deadline:
            print(result.stdout)
            print(result.stderr, file=sys.stderr)
            sys.exit("server never became ready")
        time.sleep(0.5)
