"""End-to-end test for a conda-backend opensearch: start, index, search, stop.

The pinned `conda:opensearch@3.9.0` closure includes the
`fonts-conda-forge-1` metapackage, which is built with rattler-build: its
payload is an empty tar and, unlike conda-build packages, it ships no
`info/files` manifest at all (only `info/paths.json`). Installing the closure
must recognize the metapackage from either manifest and skip its payload
instead of failing to extract it.
"""

import grp
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

from runfiles import Runfiles

r = Runfiles.Create()

REPO = "mise/tools/conda_opensearch"
tool = r.Rlocation(os.path.join(REPO, "tool"))

# The conda tool wrapper dispatches to the conda prefix's bin/ via its first
# argument (e.g. `tool opensearch --version`), while also supporting argv[0]
# dispatch for per-binary symlinks.
opensearch = [tool, "opensearch"]


def conda_prefix():
    """Returns the conda prefix the tool wrapper dispatches into.

    The wrapper exports `CONDA_PREFIX` to the binary it execs, and normally
    lives right next to that prefix's `bin/`. But depending on how the
    runfiles tree is materialized it can also sit in the hub repo, where the
    wrapper falls back to the tool's own repo inside the runfiles tree. Both
    layouts have to be handled, and neither is discoverable from the
    `CONDA_PREFIX` of the test process itself.
    """
    script_dir = os.path.dirname(os.path.realpath(tool))
    nearby = os.path.join(script_dir, "conda-prefix")
    if os.path.isdir(nearby):
        return nearby
    root = script_dir
    while root != os.sep and not root.endswith(".runfiles"):
        root = os.path.dirname(root)
    matches = sorted(
        os.path.join(root, entry, "tools", "conda_opensearch", "conda-prefix")
        for entry in os.listdir(root)
    )
    matches = [path for path in matches if os.path.isdir(path)]
    if len(matches) != 1:
        sys.exit("cannot locate the conda prefix from %s (found %r)" % (tool, matches))
    return matches[0]


# OpenSearch refuses to run as root, and remote-execution containers run as
# root, so drop privileges when we start out as root. The action PATH may not
# include /usr/sbin, so probe absolute locations too.
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


def privilege(args):
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


tmp = tempfile.mkdtemp(prefix="opensearch_e2e_")
proc = None
try:
    if DROP is not None:
        # Directories created above belong to root; hand them to the
        # unprivileged user and give it a writable HOME for good measure.
        os.chown(tmp, user.pw_uid, user.pw_gid)
        os.environ["HOME"] = tmp

    # The conda package ships the distribution in `libexec/opensearch/` and
    # exposes `bin/opensearch` as a symlink into it, which is how the launcher
    # normally finds its jars. Mirror it into the scratch dir instead, for two
    # reasons: the runfiles tree may materialize those symlinks as plain files
    # (leaving the launcher hunting for jars in `<prefix>/lib/`), and
    # `org.opensearch.secure_sm.policy.PolicyFile` resolves every
    # `modules/*/plugin-security.policy` to a real path and then URL-decodes it,
    # which turns the `+` of a Bazel canonical repository name
    # (`rules_mise++mise+mise.conda_opensearch...`) into a space and makes the
    # file unfindable. A `+`-free scratch path sidesteps both.
    home = os.path.join(tmp, "opensearch")
    run(["cp", "-a", os.path.join(conda_prefix(), "libexec", "opensearch"), home])
    if DROP is not None:
        subprocess.run(["chown", "-R", "%d:%d" % (user.pw_uid, user.pw_gid), home],
                       check=True)
    os.environ["OPENSEARCH_HOME"] = home

    # The launcher works and links the conda closure (bundled JDK, the conda
    # libstdcxx/libgcc it needs to spawn the JVM).
    version = run(opensearch + ["--version"])
    assert re.search(r"^Version: 3\.", version, re.M), (
        "unexpected version output: %r" % version
    )

    def free_port():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    port = free_port()
    env = dict(os.environ)
    # Keep the launcher off the sandbox's read-only HOME, and stay well below
    # the 1g heap the packaged jvm.options reserves.
    env["OPENSEARCH_TMPDIR"] = tmp
    env["OPENSEARCH_JAVA_OPTS"] = "-Xms512m -Xmx512m"
    # The packaged config/ (jvm.options, log4j2.properties, opensearch.yml) is
    # used as-is; every mutable path is redirected below.
    for name in ("data", "logs"):
        os.makedirs(os.path.join(tmp, name), exist_ok=True)
        if DROP is not None:
            os.chown(os.path.join(tmp, name), user.pw_uid, user.pw_gid)

    base = "http://127.0.0.1:%d" % port

    def request(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            base + path, data=data, method=method,
            headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as err:
            print(err.read().decode(), file=sys.stderr)
            raise

    proc = subprocess.Popen(
        privilege(opensearch) + ["-E", "path.data=%s" % os.path.join(tmp, "data"),
                                 "-E", "path.logs=%s" % os.path.join(tmp, "logs"),
                                 "-E", "discovery.type=single-node",
                                 "-E", "network.host=127.0.0.1",
                                 "-E", "http.port=%d" % port,
                                 "-E", "transport.port=%d" % free_port(),
                                 "-E", "bootstrap.memory_lock=false"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
        # jvm.options writes the GC log and heap dumps to relative paths.
        cwd=tmp,
    )

    # Wait until the cluster answers its root API.
    deadline = time.time() + 300
    while True:
        try:
            root = request("GET", "/")
            break
        except Exception:
            if proc.poll() is not None:
                print(proc.stdout.read() if proc.stdout else "")
                sys.exit("opensearch exited early with code %s" % proc.returncode)
            if time.time() > deadline:
                print(proc.stdout.read() if proc.stdout else "")
                sys.exit("server never became ready")
            time.sleep(1.0)

    cluster_version = root["version"]["number"]
    print("cluster up: OpenSearch %s, cluster %s" % (
        cluster_version, root["cluster_name"]))
    assert cluster_version.startswith("3."), (
        "unexpected cluster version: %r" % cluster_version
    )

    # A full write/read round-trip through the search engine.
    request("PUT", "/e2e/_doc/1?refresh=true", {"title": "rules_mise", "n": 42})
    hits = request("GET", "/e2e/_search?q=title:rules_mise")["hits"]
    assert hits["total"]["value"] == 1, "unexpected hit count: %r" % hits
    assert hits["hits"][0]["_source"]["n"] == 42, (
        "unexpected document: %r" % hits["hits"][0]
    )

    # Aggregation round-trip, which exercises the bundled modules.
    aggs = request("POST", "/e2e/_search", {
        "size": 0,
        "aggs": {"titles": {"terms": {"field": "title.keyword"}}},
    })["aggregations"]
    assert aggs["titles"]["buckets"][0]["key"] == "rules_mise", (
        "unexpected aggregation: %r" % aggs
    )

    deleted = request("DELETE", "/e2e")
    assert deleted.get("acknowledged") is True, (
        "index delete not acknowledged: %r" % deleted
    )
    indices = request("GET", "/_cat/indices?format=json")
    assert [i["index"] for i in indices] == [], (
        "index still present after delete: %r" % indices
    )
finally:
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=120)
        except subprocess.TimeoutExpired:
            proc.kill()
    shutil.rmtree(tmp, ignore_errors=True)

print("opensearch end-to-end lifecycle OK")
