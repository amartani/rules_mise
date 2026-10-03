# conda e2e

Exercises a `conda:`-backend tool (`conda:opensearch`) from an end-user's
perspective: the lockfile records the main package plus transitive
`[conda-packages]` dependencies, and `rules_mise` installs the whole closure
into a conda prefix and generates a launcher that sets the conda runtime
environment (`CONDA_PREFIX`, `PATH`, activation scripts) like `mise` does.

`test_opensearch.py` runs a full server lifecycle against the packaged
binaries: `--version` through the wrapper, then `opensearch` started as a
single-node cluster with `path.data`/`path.logs` in a scratch dir, a document
write/read round-trip over the REST API, a terms aggregation (which exercises
the bundled modules), an index delete, and a graceful shutdown. The binary is
reached through the single `@mise//tools/conda_opensearch:tool` wrapper,
which dispatches on its first argument (e.g. `tool opensearch --version`) and
also supports `argv[0]` dispatch for per-binary symlinks.

## The metapackage this test exists for

The pinned `conda:opensearch@3.9.0` closure pulls in the
`fonts-conda-forge-1` metapackage on Linux. It is built with
[rattler-build](https://github.com/prefix-dev/rattler-build), whose packages
carry `info/paths.json` (the file list in JSON form) and **no** `info/files`
manifest at all — unlike conda-build packages, which write the newline
separated `info/files`. Its `pkg-*.tar.zst` payload is an empty tar, which
Bazel's extractor rejects, so `rules_mise` must recognize it as a metapackage
and skip the payload. Consulting `info/files` alone misses it: the manifest is
absent, so the package looks like an ordinary one and the fetch fails with
`Prefix "" was given, but not found in the archive`. See
`mise/hub.bzl:_download_extract_conda`, which falls back to
`info/paths.json` when `info/files` is missing.

## Note on remote execution

Three things are needed to run this test on BuildBuddy's remote executors:

- The conda-forge builds need a modern glibc, while BuildBuddy's default
  execution platform is Ubuntu 16.04 (glibc 2.23), so the repo's `buildbuddy`
  configs set `container-image` to the Ubuntu 24.04 image from
  `buildbuddy-io/buildbuddy-toolchain` (`UBUNTU24_04_IMAGE`) as the default
  for all remote actions.
- Containers run as root and OpenSearch refuses to start as root, so the test
  drops privileges via `setpriv`/`runuser` to `nobody` when it starts as root
  (and `chown`s its scratch dirs accordingly). `OPENSEARCH_JAVA_OPTS` also
  caps the heap at 512m instead of the packaged 1g default.
- The distribution is mirrored into the scratch dir before the server starts.
  `org.opensearch.secure_sm.policy.PolicyFile` resolves every
  `modules/*/plugin-security.policy` to a real path and then URL-decodes it,
  which turns the `+` of a Bazel canonical repository name
  (`rules_mise++mise+mise.conda_opensearch...`) into a space and leaves the
  file unfindable. The same mirror covers the other way the launcher can lose
  its jars: `bin/opensearch-env` finds `OPENSEARCH_HOME` by resolving the
  `bin/opensearch` symlink into `libexec/opensearch/`, and a runfiles tree
  that materializes symlinks as plain files breaks that walk. A `+`-free
  scratch path with a real distribution sidesteps both. `JAVA_HOME` still
  points into the conda prefix, so the bundled JDK is still the conda one.

Related `rules_mise` behavior worth knowing: conda packages (`.conda` files)
are zipped `tar.zst` archives. The tool repo extracts the outer zip with
Bazel's built-in zip support, then extracts the inner `pkg-*.tar.zst` with
Bazel's built-in `tar.zst` support (available in Bazel 8+), overlaying all
packages into a shared `conda-prefix/` layout. Build-prefix placeholders
from each package's `info/has_prefix` are replaced at fetch time with a short
stable prefix (`/tmp/mise_conda_<hash>`, text as plain replacement, binaries
null-padded like `conda` does so file sizes are preserved); at tool runtime
the wrapper symlinks that stable prefix to the real `CONDA_PREFIX` (which
lives under Bazel runfiles and differs between local and remote execution).

## Note on regenerating `mise.lock`

`mise.toml` pins `conda:opensearch@3.9.0`, which solves on all supported
platforms (`linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`,
`windows-x64`). `mise.lock` is `@generated` by `mise lock`; do not hand-edit
it.
