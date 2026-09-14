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

def _split_dep_id(dep_id):
    parts = dep_id.rsplit("@", 1)
    if len(parts) != 2:
        fail("Invalid pkgx package id '{id}': expected <name>@<version>".format(id = dep_id))
    return (parts[0], parts[1])

def _pkgx_payload(tool_name, backend, version, url, checksum, platform, platform_data, pkgx_packages):
    """Builds the pkgx closure payload for one platform entry of a pkgx tool.

    Mirrors `mise install` from a lockfile: the main bottle plus every
    transitive dependency listed in `pkgx_deps`, with bottle info taken from
    the shared `[pkgx-packages]` lockfile section (deps first, root last).
    """
    root = backend[len("pkgx:"):]
    provides = [
        p
        for p in platform_data.get("pkgx_provides", [])
        if p.startswith("bin/") or p.startswith("sbin/")
    ]
    platform_pkgs = pkgx_packages.get(platform, {})
    packages = []
    for dep_id in platform_data.get("pkgx_deps", []):
        info = platform_pkgs.get(dep_id, None)
        if info == None:
            fail("pkgx tool {tool}: dependency {dep} has no [pkgx-packages.{platform}] entry in the lockfile".format(
                tool = tool_name,
                dep = dep_id,
                platform = platform,
            ))
        (dep_name, dep_version) = _split_dep_id(dep_id)
        packages.append({
            "name": dep_name,
            "version": dep_version,
            "url": info.get("url", ""),
            "checksum": _strip_sha256(info.get("checksum", "")),
            "runtime_env": info.get("pkgx_runtime_env", {}),
        })
    packages.append({
        "name": root,
        "version": version,
        "url": url,
        "checksum": checksum,
        "runtime_env": platform_data.get("pkgx_runtime_env", {}),
    })
    return {
        "root": root,
        "version": version,
        "provides": provides,
        "packages": packages,
    }

def _load(ctx, lockfiles):
    tools = {}
    for lockfile in lockfiles:
        parsed = toml.decode(ctx.read(lockfile))
        pkgx_packages = parsed.get("pkgx-packages", {})

        tools_dict = parsed.get("tools", {})
        for tool_name, tool_data in tools_dict.items():
            if type(tool_data) == "list":
                tool_entries = tool_data
            else:
                tool_entries = [tool_data]

            binaries = []
            version = ""
            backend = ""
            hint = _exe_hint(tool_name)
            unverified = False

            for tool_entry in tool_entries:
                entry_version = tool_entry.get("version", "")
                entry_backend = tool_entry.get("backend", "")
                if not version:
                    version = entry_version
                if not backend:
                    backend = entry_backend

                is_pkgx = entry_backend.startswith("pkgx:")

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
                        "version": entry_version,
                        "backend": entry_backend,
                        "hint": hint,
                    }
                    if is_pkgx:
                        if kind != "archive":
                            fail("pkgx tool {tool}: expected an archive bottle, got {url}".format(
                                tool = tool_name,
                                url = url,
                            ))
                        binary["pkgx"] = _pkgx_payload(
                            tool_name,
                            entry_backend,
                            entry_version,
                            url,
                            checksum,
                            platform_suffix,
                            platform_data,
                            pkgx_packages,
                        )
                    binaries.append(binary)

            if binaries:
                clean_name = _clean(tool_name)
                provides = []
                for binary in binaries:
                    if "pkgx" in binary:
                        provides = binary["pkgx"]["provides"]
                        break
                if unverified:
                    unverified_message = "rules_mise: tool '{tool}' has platforms without checksums in {lockfile}, those downloads will not be verified".format(
                        tool = tool_name,
                        lockfile = lockfile,
                    )
                    print(unverified_message)  # buildifier: disable=print
                tools[clean_name] = {
                    "binaries": binaries,
                    "version": version,
                    "backend": backend,
                    "provides": provides,
                }
            else:
                # Tools without downloadable binaries (e.g. language-manager
                # backends like `npm:`/`cargo:`/`go:` that build from source,
                # or single-file-compressed URLs we cannot extract) cannot
                # be exposed as Bazel targets. Say so instead of silently
                # dropping them.
                skip_message = "rules_mise: tool '{tool}' has no supported platforms with a downloadable url in {lockfile}, skipping".format(
                    tool = tool_name,
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
