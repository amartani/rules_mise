"""End-to-end test for a conda-backend redis: start server, ping, set/get, stop.

The pinned `conda:redis-server@7.2.4` closure includes the `libgcc-ng`
metapackage, which ships no files (empty `pkg-*.tar.zst`, empty
`info/files` manifest). Installing the closure must skip that payload
instead of failing to extract it.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from runfiles import Runfiles

r = Runfiles.Create()

REPO = "mise/tools/conda_redis-server"
tool = r.Rlocation(os.path.join(REPO, "tool"))

# The conda tool wrapper dispatches to the conda prefix's bin/ via its first
# argument (e.g. `tool redis-server --version`), while also supporting
# argv[0] dispatch for per-binary symlinks.
redis_server = [tool, "redis-server"]
redis_cli = [tool, "redis-cli"]


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        sys.exit(result.returncode)
    return result.stdout


# The server binary itself works and links the conda closure.
version = run(redis_server + ["--version"])
assert "Redis server" in version, "unexpected version: %r" % version


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


tmp = tempfile.mkdtemp(prefix="redis_e2e_")
port = free_port()
proc = None
try:
    proc = subprocess.Popen(
        redis_server + [
            "--port", str(port),
            "--bind", "127.0.0.1",
            "--save", "",
            "--appendonly", "no",
            "--dir", tmp,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    # Wait until the server answers PING.
    deadline = time.time() + 60
    while True:
        ready = subprocess.run(
            redis_cli + ["-p", str(port), "ping"],
            capture_output=True, text=True)
        if ready.returncode == 0 and "PONG" in ready.stdout:
            break
        if proc.poll() is not None:
            out = proc.stdout.read() if proc.stdout else ""
            print(out)
            sys.exit("redis-server exited early with code %s" % proc.returncode)
        if time.time() > deadline:
            print(ready.stdout)
            print(ready.stderr, file=sys.stderr)
            sys.exit("server never became ready")
        time.sleep(0.5)

    out = run(redis_cli + ["-p", str(port), "set", "e2e", "42"])
    assert "OK" in out, "unexpected SET result: %r" % out
    out = run(redis_cli + ["-p", str(port), "get", "e2e"])
    assert out.strip() == "42", "unexpected GET result: %r" % out
finally:
    if proc is not None and proc.poll() is None:
        subprocess.run(
            redis_cli + ["-p", str(port), "shutdown", "nosave"],
            capture_output=True, text=True)
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
    shutil.rmtree(tmp, ignore_errors=True)

print("redis end-to-end lifecycle OK")
