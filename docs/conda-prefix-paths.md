# Conda Prefix Paths in Runfiles

Two failure modes hit conda tools whose binaries locate themselves from their
own filesystem path. Both surface **only on remote execution**, both produce
errors that point nowhere near the cause, and neither is specific to the tool
that exposed them. This document records the problem, the evidence, and a set
of proposed changes.

The tool that surfaced them is `conda:opensearch` (see
`e2e/conda_opensearch`), whose distribution self-locates through symlinks and
ships JVM security policy files.

## Symptoms

### 1. Launcher looks for jars in the wrong directory

```text
Error: Could not find or load main class
  org.opensearch.tools.java_version_checker.JavaVersionChecker
Caused by: java.lang.ClassNotFoundException: ...
```

The distribution ships as `libexec/opensearch/`, with `bin/opensearch` a
symlink into it. `bin/opensearch-env` finds its home by resolving `$0`
through symlinks and walking up to the enclosing `bin/`. When the symlink has
been dereferenced, the walk stops one level too early and the classpath
becomes `<prefix>/lib/*`, which does not exist.

### 2. `+` in the prefix path is decoded as a space

```text
java.lang.IllegalArgumentException: unable to parse policy file
  `file:/.../rules_mise++mise+mise.conda_opensearch.linux_x86_64/tools/.../plugin-security.policy`
Likely root cause: java.io.FileNotFoundException:
  /.../rules_mise  mise mise.conda_opensearch.linux_x86_64/.../plugin-security.policy
```

`org.opensearch.secure_sm.policy.PolicyFile` resolves each
`modules/*/plugin-security.policy` with `Path.toRealPath()`, then runs the
result through `URLDecoder.decode()` (correct for query strings, wrong for
file paths). `+` becomes a space, so the file cannot be opened.

## Root cause 1: the runfiles tree materializes symlinks as plain files

The `conda_files` filegroup lists symlinks explicitly so the runfiles tree can
recreate them (`mise/hub.bzl`). That only works when the executor materializes
the input tree as a symlink forest. It does not always.

Observed on the same commit, same machine, two executors:

```text
# local: runfiles/.../tools/conda_opensearch/conda-prefix/bin/opensearch
  islink True   -> ../libexec/opensearch/bin/opensearch

# BuildBuddy: same path
  islink False  (a regular file holding a copy of the script)
```

This is not opensearch-specific. The `conda:opensearch` prefix contains
**1653** symlinks (`share/terminfo` 1038, `lib/jvm` 205, `share/man` 51,
`include/ncurses*` 36, …) and the `conda:postgresql` prefix is **160 MB**.
Any executor that dereferences the input tree duplicates all of them, and
breaks every binary that resolves its own location through a symlink.

`rules_mise` depends on symlink semantics here but nowhere documents or
asserts it, which is the actual defect. Which executors can be asked to
preserve symlinks needs confirming before relying on any flag.

## Root cause 2: `+` is unavoidable in bzlmod canonical repository names

The tool repo lands in the runfiles tree under Bazel's canonical name for a
module-extension repo:

```text
<module_name>++<extension_name>+<repo_name>
rules_mise++mise+mise.conda_opensearch.linux_x86_64
```

The `++` and `+` separators are Bazel's format, so no choice of `hub_name`
avoids them. (`lockfile.bzl`'s `_clean` already strips `+` from *tool names*;
that is orthogonal — it sanitizes the target label, not the directory the
label resolves to.)

Local execution escapes this by accident. Bazel points runfiles symlinks at
the repository cache, whose content-addressed directories are `+`-free:

```text
/buildbuddy-execroot/external/rules_mise++mise+mise.conda_opensearch...  # remote
/home/.../cache/repos/v1/contents/<sha>/tools/conda_opensearch/conda-prefix  # local
```

So the `+` is in the path on any executor that materializes the tree rather
than symlinking into the repo cache — i.e. exactly the remote case.

## Why this is only partly ours

The `URLDecoder.decode()` in OpenSearch (inherited from Elasticsearch) is an
upstream bug, and it is not the only consumer that mishandles its own path.
Anything that parses a path as a URL breaks the same way.

That does not make it a non-issue for `rules_mise`: the prefix path is chosen
by the rule set, and there is currently no way to ask for a prefix that is
safe for such consumers. The proposals below are about giving users that
control, not about working around one upstream bug.

## Current workaround (in `e2e/conda_opensearch`)

`test_opensearch.py` mirrors the distribution into its scratch directory before
starting the server:

```python
home = os.path.join(tmp, "opensearch")
run(["cp", "-a", os.path.join(conda_prefix(), "libexec", "opensearch"), home])
os.environ["OPENSEARCH_HOME"] = home
```

The scratch path is real (so `toRealPath()` stops there) and `+`-free, which
fixes both symptoms at once. `JAVA_HOME` still resolves into the conda prefix,
so the bundled JDK is still the conda one.

Two costs make this a poor thing to leave as the only answer:

- **191 MB copied per test run.** `cp -a --reflink=auto` would be nearly free
  on a CoW-capable filesystem; `--reflink=auto` is not the default.
- **`conda_prefix()` is duplicated logic.** The test re-implements the
  dispatcher's two-layout resolution (~20 lines) because the resolved prefix
  is not exposed as a target.

## Proposed changes

Ordered by value per unit of risk. P1 and P2 are independent and can land
separately; P4 is the real fix but needs the P5 validation first.

### P1 — Fail loudly when the prefix cannot be resolved

`mise/hub.bzl:303-320` tries two layouts and then unconditionally runs
`export CONDA_PREFIX="$SCRIPT_DIR/conda-prefix"`. If neither resolves, the
wrapper execs the binary against a nonexistent prefix, which is why symptom 1
surfaced as a JVM `ClassNotFoundException` rather than a path error.

```bash
if [ ! -d "$CONDA_PREFIX" ]; then
  echo "rules_mise: cannot locate the conda prefix for <tool>" \
       "(tried '$script_dir/conda-prefix' and '$runfiles_root/...')" >&2
  exit 1
fi
```

The same commit should add the layout the dispatcher is missing.
`run_in.template.sh:17-24` handles three — sibling, `$RUNFILES_DIR`, and
`$RUNFILES_MANIFEST_FILE` (by grepping the manifest) — while the conda
dispatcher only walks directories. Manifest-only runfiles is a real mode, so
the dispatcher would fail there silently today.

Cost: small. Risk: low; it converts a confusing failure into a clear one.

### P2 — Expose the resolved prefix as a target

`run_in.bzl` already establishes the pattern: generate a wrapper that resolves
across layouts at runtime. Add a sibling to `:tool`, `:cwd` and
`:workspace_root` that prints the conda environment instead of execing it:

```python
env = dict(os.environ, **json.loads(
    subprocess.run([r.Rlocation("mise/tools/conda_opensearch/tool_env")],
                   capture_output=True, text=True, check=True).stdout))
```

One implementation of the resolution instead of two, and every e2e test that
needs a path inside the prefix stops hand-rolling it. Emitting the full
environment rather than just `CONDA_PREFIX` also covers consumers that need
`PATH` or the activation-script results.

Cost: small (template plus a rule). Risk: low.

### P3 — A supported knob for tool-specific environment

`OPENSEARCH_HOME` is the kind of value a user should set once, declaratively,
rather than at every call site in a test:

```python
mise.hub(
    lockfile = "//:mise.lock",
    tool_env = {
        "conda_opensearch": {
            "OPENSEARCH_HOME": "$CONDA_PREFIX/libexec/opensearch",
        },
    },
)
```

with `$CONDA_PREFIX` expanded when the dispatcher is generated. `hub()` has no
such attribute today; `mise.conda_env` already has an `envs` concept, so the
naming needs care to avoid confusion with it.

This removes the repeated `env=` plumbing in tests and fixes *this* symptom.
It does not fix root cause 1 in general, because a package can self-locate in
ways no environment variable reaches.

Cost: small. Risk: low.

### P4 — Opt-in materialized prefix (fixes both symptoms)

The dispatcher already publishes a stable, runfiles-independent prefix at
`/tmp/mise_conda_<hash>` (`mise/hub.bzl:275`), created at tool runtime because
only then is the real `CONDA_PREFIX` known. Extend it so that, for tools that
opt in, that path is a **real directory** rather than a symlink:

```bash
cp -a --reflink=auto "$CONDA_PREFIX/." "$staging/" && mv "$staging" "$_MISE_PLAIN"
```

Staging plus a rename keeps concurrent first runs from interleaving, the same
concern the existing `ln -s` (deliberately without `-f`) addresses. The rename
is atomic because the target does not exist yet; `mv -T` is not needed and
would be a GNU-only dependency this rule set cannot take, since it also
supports macOS.

That one change resolves both symptoms for every self-locating tool, and it
removes the 191 MB mirror from the test:

- `$CONDA_PREFIX` is `+`-free, so `URLDecoder.decode()` is harmless
- it is a real tree with intact symlinks, so the `$0` walk in
  `opensearch-env` resolves correctly
- users hitting this with their own JVM or `.NET` tool get fixed without
  knowing any of this exists

**It must be opt-in.** 160 MB (postgres) / 191 MB (opensearch) per prefix,
copied on first invocation, is not a reasonable default to impose on every
conda user to fix a JVM-specific problem. A per-tool flag makes both the cost
and the escape hatch visible:

```python
mise.hub(lockfile = "//:mise.lock", plain_prefix = ["conda_opensearch"])
```

Note that sanitizing the prefix to a `+`-free path is unavoidable rather than
cosmetic, for the reason in root cause 2.

Cost: medium. Risk: medium — see P5, and the staleness of the copied tree if a
tool writes into `CONDA_PREFIX` (the conda layout says it should not).

### P5 — Validate the copy cost on the target executor

`cp --reflink=auto` is nearly free on btrfs/xfs and degrades to a full copy
elsewhere. On an executor whose container filesystem supports neither CoW nor
reflinks, the opt-in flag in P4 becomes a 190 MB copy on every cold worker,
which changes its character from "prudent" to "load-bearing".

Measure before committing to P4: check reflink support on the BuildBuddy
container filesystem, and time a cold copy.

Cost: small. Risk: none (measurement only). Blocks P4.

### P6 — A generic reflink copy helper

The test shells out to `cp -a`. A small `copy_directory` rule, or at minimum
documenting the `--reflink=auto` idiom, keeps e2e workspaces from
re-deriving it. Hardlinks (`cp -al`) are cheaper still but share inodes, so
anything a tool writes would corrupt the runfiles tree — worth documenting as
a trap rather than defaulting to it.

Cost: small. Risk: low.

### P7 — Document both hazards

Neither root cause is discoverable from the code or from the error messages.
`docs/architecture.md` describes the dispatcher's symlink resolution without
noting that it assumes a symlink forest, and nothing records that bzlmod
canonical repo names contain `+`.

Cost: small. Risk: none.

## Recommendation

1. **P1** — diagnostics; would have cut the initial investigation
   substantially on its own.
2. **P2** — removes real duplication and makes every future e2e cheaper.
3. **P5** (measure), then **P4** as opt-in — the actual fix.
4. **P3**, **P6**, **P7** — independent cleanups.

## Open questions

- Can BuildBuddy's executor be configured to preserve input-tree symlinks? If
  so, root cause 1 is partly an executor configuration question and P4 is
  narrower than it looks.
- Which executors currently dereference the input tree? Only local and
  BuildBuddy were exercised here.
- Do other conda tools in common use self-locate through symlinks? `psql`,
  `initdb` and `pg_ctl` are real files in the postgres prefix, which is why
  `e2e/conda` passes on remote execution even though that prefix also carries
  1420 symlinks. Exposure is therefore wider than the passing tests suggest:
  the 1653 in the opensearch prefix include 205 from the bundled openjdk.
- Should P4 cover non-conda tools too? The `+` hazard applies to any tool that
  parses its own path, but only conda tools get a prefix that the rule set
  controls.
