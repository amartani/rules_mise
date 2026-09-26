"Utilities for interacting with the mise lockfile."

load("@toml.bzl", "toml")

_MISE_PLATFORM_TO_BAZEL = {
    "linux-arm64": struct(os = "linux", cpu = "arm64"),
    "linux-x64": struct(os = "linux", cpu = "x86_64"),
    "macos-arm64": struct(os = "macos", cpu = "arm64"),
    "macos-x64": struct(os = "macos", cpu = "x86_64"),
    "windows-x64": struct(os = "windows", cpu = "x86_64"),
}

_MUSL_VARIANTS = {
    "linux-x64-musl": "linux-x64",
    "linux-arm64-musl": "linux-arm64",
}

_ARCHIVE_SUFFIXES = [".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar", ".zip"]

# Single-file compression suffixes that are NOT archives: a lone `.gz`
# (e.g. taplo's `taplo-linux-x86_64.gz`) is one compressed binary, not a
# container Bazel could extract, so entries with these URLs are skipped.
_SINGLE_FILE_SUFFIXES = [".gz", ".bz2", ".xz", ".zst"]

def _clean(name):
    """Sanitizes a mise tool/package name for use in Bazel labels and paths.

    Only characters that are illegal in labels, repo names, or paths are
    replaced (`:`, `/`, `+`, `@`, space); `-` and `.` are kept so existing
    tool names are unaffected.
    """
    return (name.replace(":", "_").replace("/", "_").replace("+", "_")
        .replace("@", "_").replace(" ", "_"))

def _exe_hint(tool_name):
    """Best-effort executable name for archive discovery.

    Tool names may carry a backend prefix (`npm:prettier`,
    `aqua:org/name/tool`), while the archived binary is usually just the
    trailing segment (`prettier`, `tool`).
    """
    return tool_name.rsplit(":", 1)[-1].rsplit("/", 1)[-1]

def _strip_sha256(checksum):
    if checksum.startswith("sha256:"):
        return checksum[len("sha256:"):]
    if ":" in checksum:
        # Bazel only verifies SHA-256. Other algorithms recorded by mise
        # (e.g. `blake3:`) cannot be passed to `rctx.download(sha256 = ...)`
        # and are treated as unverified, like entries with no checksum.
        return ""
    return checksum

def _is_archive(url):
    lower_url = url.lower()
    for suffix in _ARCHIVE_SUFFIXES:
        if lower_url.endswith(suffix):
            return True
    return False

def _is_single_file_compressed(url):
    """Whether the URL is a single compressed file rather than an archive."""
    lower_url = url.lower()
    for suffix in _ARCHIVE_SUFFIXES:
        if lower_url.endswith(suffix):
            return False
    for suffix in _SINGLE_FILE_SUFFIXES:
        if lower_url.endswith(suffix):
            return True
    return False

def _parse_mise_platform(platform):
    if platform in _MUSL_VARIANTS:
        return None
    if platform in _MISE_PLATFORM_TO_BAZEL:
        return _MISE_PLATFORM_TO_BAZEL[platform]
    return None

def _conda_basename(url):
    """Derives the conda package basename from its URL.

    E.g. `.../postgresql-18.4-h3dddfe3_1.conda` -> `postgresql-18.4-h3dddfe3_1`,
    `.../libntlm-1.4-hf897c2e_1002.tar.bz2` -> `libntlm-1.4-hf897c2e_1002`.
    """
    filename = url.rsplit("/", 1)[-1]
    if filename.endswith(".conda"):
        return filename[:-len(".conda")]
    if filename.endswith(".tar.bz2"):
        return filename[:-len(".tar.bz2")]
    return filename

def _conda_payload(tool_name, url, checksum, platform, platform_data, conda_packages):
    """Builds the conda closure payload for one platform entry of a conda tool.

    Mirrors `mise install` from a lockfile: the main package plus every
    transitive dependency listed in `conda_deps`, with package info taken from
    the shared `[conda-packages]` lockfile section (deps first, main last).
    """
    platform_pkgs = conda_packages.get(platform, {})
    packages = []
    for dep_id in platform_data.get("conda_deps", []):
        info = platform_pkgs.get(dep_id, None)
        if info == None:
            fail("conda tool {tool}: dependency {dep} has no [conda-packages.{platform}] entry in the lockfile".format(
                tool = tool_name,
                dep = dep_id,
                platform = platform,
            ))
        packages.append({
            "basename": dep_id,
            "url": info.get("url", ""),
            "checksum": _strip_sha256(info.get("checksum", "")),
        })
    packages.append({
        "basename": _conda_basename(url),
        "url": url,
        "checksum": checksum,
    })
    return {
        "packages": packages,
    }

def _tool_key(tool_name, version, multi_version, index):
    """Returns the Bazel tool key for one version group of a lockfile tool.

    A tool requested at a single version keeps the legacy `_clean(tool_name)`
    key so existing labels are unaffected. When a tool is requested at
    multiple versions (`"conda:postgresql" = ["17.7", "18.4"]`), each version
    becomes its own tool keyed by `_clean(tool_name + "@" + version)` (e.g.
    `conda_postgresql_17.7`), reusing the `_clean` sanitizing. Entries
    without a version fall back to a positional suffix.
    """
    if not multi_version:
        return _clean(tool_name)
    if version:
        return _clean(tool_name + "@" + version)
    return "{clean}_{n}".format(clean = _clean(tool_name), n = index + 1)

def _load(ctx, lockfiles):
    tools = {}
    for lockfile in lockfiles:
        parsed = toml.decode(ctx.read(lockfile))
        conda_packages = parsed.get("conda-packages", {})

        tools_dict = parsed.get("tools", {})
        for tool_name, tool_data in tools_dict.items():
            if type(tool_data) == "list":
                tool_entries = tool_data
            else:
                tool_entries = [tool_data]

            # A tool requested at multiple versions is recorded as one list
            # entry per version. Group entries by version so each version
            # becomes its own Bazel tool: merging them would emit duplicate
            # (os, cpu) binaries under a single tool name, and the hub cannot
            # create two repos with the same name. Entries sharing a version
            # (e.g. distribution-specific duplicates) stay merged, preserving
            # the previous behavior for them.
            versions = []
            grouped = {}
            for tool_entry in tool_entries:
                entry_version = tool_entry.get("version", "")
                if entry_version not in grouped:
                    grouped[entry_version] = []
                    versions.append(entry_version)
                grouped[entry_version].append(tool_entry)
            multi_version = len(versions) > 1

            for index, entry_version in enumerate(versions):
                version_entries = grouped[entry_version]
                binaries = []
                version = ""
                backend = ""
                hint = _exe_hint(tool_name)
                unverified = False

                for tool_entry in version_entries:
                    entry_backend = tool_entry.get("backend", "")
                    if not version:
                        version = tool_entry.get("version", "")
                    if not backend:
                        backend = entry_backend

                    is_conda = entry_backend.startswith("conda:")

                    for platform_key, platform_data in tool_entry.items():
                        if not platform_key.startswith("platforms."):
                            continue

                        platform_suffix = platform_key[len("platforms."):]
                        bazel_constraints = _parse_mise_platform(platform_suffix)
                        if not bazel_constraints:
                            continue

                        url = platform_data.get("url", "")
                        if not url or _is_single_file_compressed(url):
                            continue

                        # Checksums are optional: backends such as `http:` (and
                        # some `gitlab:` releases) record no checksum, so those
                        # downloads cannot be verified and are marked
                        # non-reproducible in the tool repo.
                        checksum = _strip_sha256(platform_data.get("checksum", ""))
                        if not checksum:
                            unverified = True

                        lower_url = url.lower()
                        if _is_archive(url):
                            kind = "archive"
                        elif lower_url.endswith(".pkg"):
                            kind = "pkg"
                        else:
                            kind = "file"

                        binary = {
                            "os": bazel_constraints.os,
                            "cpu": bazel_constraints.cpu,
                            "url": url,
                            "checksum": checksum,
                            "kind": kind,
                            "version": tool_entry.get("version", ""),
                            "backend": entry_backend,
                            "hint": hint,
                        }
                        if is_conda:
                            binary["conda"] = _conda_payload(
                                tool_name,
                                url,
                                checksum,
                                platform_suffix,
                                platform_data,
                                conda_packages,
                            )
                        binaries.append(binary)

                display_name = tool_name
                if multi_version and entry_version:
                    display_name = tool_name + "@" + entry_version
                if binaries:
                    clean_name = _tool_key(tool_name, entry_version, multi_version, index)
                    if multi_version:
                        # No `while` in Starlark; at most len(tools) candidates
                        # collide, so this loop always terminates with a free key
                        # and never clobbers an unrelated tool.
                        base_name = clean_name
                        suffix = 2
                        for _ in range(len(tools) + 1):
                            if clean_name not in tools:
                                break
                            clean_name = "{base}_{n}".format(base = base_name, n = suffix)
                            suffix += 1
                    if unverified:
                        unverified_message = "rules_mise: tool '{tool}' has platforms without checksums in {lockfile}, those downloads will not be verified".format(
                            tool = display_name,
                            lockfile = lockfile,
                        )
                        print(unverified_message)  # buildifier: disable=print
                    tools[clean_name] = {
                        "binaries": binaries,
                        "version": version,
                        "backend": backend,
                    }
                else:
                    # Tools without downloadable binaries (e.g. language-manager
                    # backends like `npm:`/`cargo:`/`go:` that build from source,
                    # or single-file-compressed URLs we cannot extract) cannot
                    # be exposed as Bazel targets. Say so instead of silently
                    # dropping them.
                    skip_message = "rules_mise: tool '{tool}' has no supported platforms with a downloadable url in {lockfile}, skipping".format(
                        tool = display_name,
                        lockfile = lockfile,
                    )
                    print(skip_message)  # buildifier: disable=print
    return tools

def _sorted(tools):
    return sorted(tools.items())

lockfile = struct(
    load_defs = _load,
    sorted_defs = _sorted,
)
