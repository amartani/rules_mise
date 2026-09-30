"""End-to-end test for a conda env holding postgresql + pgvector.

Each mise tool is installed into its own conda prefix, so `conda:pgvector`
alone is useless: an extension's control file and shared library must sit in
the *same* prefix as the server that loads them. This test pins that
requirement down by running a server out of the `pg` env and exercising
pgvector through it.
"""

import os
import shutil
import subprocess
import sys
import tempfile

import pg_test_lib as lib

ENV = "pg"

tool = lib.tool_name
psql = tool(ENV, "psql")
initdb = tool(ENV, "initdb")
pg_ctl = tool(ENV, "pg_ctl")
pg_isready = tool(ENV, "pg_isready")

DROP, USER = lib.drop_privileges()


def run(args, check=True):
    result = subprocess.run(args, capture_output=True, text=True)
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    if check and result.returncode != 0:
        sys.exit(result.returncode)
    return result.stdout


def query(sockdir, sql, check=True):
    return run(lib.as_postgres(psql + [
        "-h", sockdir, "-U", "postgres", "-tAc", sql,
    ], DROP), check=check)


# Unix socket paths are limited to ~107 chars, so keep everything under /tmp
# instead of the (potentially very deep) Bazel test tmpdir.
tmp = tempfile.mkdtemp(prefix="pgvector_e2e_")
pgdata = os.path.join(tmp, "data")
sockdir = os.path.join(tmp, "sock")
os.mkdir(sockdir)
if USER is not None:
    # Directories created above belong to root; hand them to the
    # unprivileged user and give it a writable HOME for good measure.
    lib.chown_tree(tmp, USER)
    os.environ["HOME"] = sockdir

started = False
try:
    run(lib.as_postgres(initdb + [
        "-D", pgdata, "-U", "postgres", "--auth=trust",
        "--no-locale", "-E", "UTF8",
    ], DROP))
    logfile = os.path.join(tmp, "server.log")
    run(lib.as_postgres(pg_ctl + [
        "-D", pgdata, "-l", logfile, "-w", "-t", "60", "start",
        "-o", "-c listen_addresses='' -k %s" % sockdir,
    ], DROP))
    started = True
    lib.wait_ready(lib.as_postgres(pg_isready + ["-h", sockdir], DROP))

    # The extension must be visible to a server started from this env.
    query(sockdir, "CREATE EXTENSION vector;")

    # And actually usable: a vector column, a few rows, and an ORDER BY over
    # the distance operator, which is the whole point of pgvector.
    query(sockdir, """
        CREATE TABLE docs (id int primary key, embedding vector(3));
        INSERT INTO docs VALUES
            (1, '[1,0,0]'), (2, '[0,1,0]'), (3, '[0.9,0.1,0]');
    """)
    near = query(sockdir,
                 "SELECT id FROM docs ORDER BY embedding <-> '[1,0,0]' LIMIT 2;")
    assert near.strip().splitlines() == ["1", "3"], (
        "unexpected nearest-neighbour order: %r" % near
    )

    # `<#>` is the negated inner product, so [1,0,0] vs [1,2,3] gives -1.
    neg = query(sockdir, "SELECT embedding <#> '[1,2,3]' FROM docs WHERE id = 1;")
    assert neg.strip() == "-1", "unexpected negative inner product: %r" % neg

    # `<->` is the euclidean distance; [0,1,0] to [1,0,0] is sqrt(2).
    dist = query(sockdir, "SELECT embedding <-> '[1,0,0]' FROM docs WHERE id = 2;")
    assert abs(float(dist.strip()) - 2 ** 0.5) < 1e-6, (
        "unexpected euclidean distance: %r" % dist
    )

    count = query(sockdir,
                  "SELECT count(*) FROM pg_extension WHERE extname = 'vector';")
    assert count.strip() == "1", "vector extension not registered: %r" % count

    # The conda-forge postgres build bakes its build prefix into the
    # --with-system-tzdata path, so without build-prefix placeholder
    # replacement every timezone lookup fails with "could not open
    # directory .../share/zoneinfo". Exercise pg_timezone_names and a named
    # time zone to cover the conda prefix-replacement logic. The env's
    # relocation pass has to patch the manifests of *every* merged package,
    # not just one closure, so this is worth asserting here too.
    tz_count = query(sockdir, "SELECT count(*) FROM pg_timezone_names();")
    assert int(tz_count.strip()) > 100, (
        "unexpected timezone count: %r" % tz_count
    )
    tz_now = query(sockdir, "SET timezone='America/New_York'; SELECT now();")
    assert tz_now.strip(), "empty result for timezone query: %r" % tz_now

    print("pgvector end-to-end OK")
finally:
    if started:
        subprocess.run(
            lib.as_postgres(pg_ctl + ["-D", pgdata, "-m", "fast", "stop"], DROP),
            capture_output=True, text=True)
    shutil.rmtree(tmp, ignore_errors=True)
