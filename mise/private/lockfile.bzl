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

def _conda_pkg_parts(basename):
    """Splits a conda package basename into `(name, version, build)`.

    Conda package filenames are `<name>-<version>-<build>`, and the split is
    from the right: only the version and build fields are known to be free of
    `-`, so a name like `libxml2-16` stays intact. The two `libxml2*` packages
    of the same version are genuinely distinct conda packages and are named
    differently, which is why this splitting is safe.
    """
    fields = basename.split("-")
    if len(fields) < 3:
        return basename, "", ""
    return "-".join(fields[:-2]), fields[-2], fields[-1]

def _version_segment(segment, numeric):
    # Numeric segments sort before alphabetic ones and compare as numbers
    # (`18.10` > `18.9`); alphabetic segments (e.g. `1.0rc1`) compare as
    # strings. Every segment is the same 3-tuple shape so tuples and the
    # lists of them built by `_conda_version_key` stay mutually comparable.
    if numeric:
        return (0, int(segment), "")
    return (1, 0, segment)

def _conda_version_key(version):
    """A comparable key approximating conda's version ordering.

    The version is split into runs of digits and non-digits; each run becomes
    a tuple that sorts numerically when it is a number and lexically
    otherwise. Comparing the resulting lists compares the versions
    segment-wise, and a prefix sorts before its extensions (`18.4` < `18.4.1`).
    """
    key = []
    segment = ""
    segment_numeric = None
    for i in range(len(version)):
        char = version[i]
        is_numeric = char.isdigit()
        if is_numeric != segment_numeric:
            if segment:
                key.append(_version_segment(segment, segment_numeric))
            segment = ""
            segment_numeric = is_numeric
        segment += char
    if segment:
        key.append(_version_segment(segment, segment_numeric))
    return key

def _merge_conda_packages(env_name, os_cpu, member_binaries):
    """Unifies the package closures of an env's members into one list.

    A single conda environment holds exactly one build of each package, so
    closures that disagree (e.g. `libpq` 18.4 for `postgresql` vs 18.6 for
    `pgvector`) cannot all be installed side by side: they would overwrite
    each other's files. The highest version wins, which is the choice conda's
    own solver converges on, and every dropped build is reported so the merge
    is never silent.

    The result keeps the input ordering (dependencies before the packages
    that pull them in), with replaced entries updated in place so the install
    order stays deterministic.
    """
    chosen = {}
    packages = []
    for binary in member_binaries:
        for package in binary["conda"]["packages"]:
            name, version, _build = _conda_pkg_parts(package["basename"])
            key = (_conda_version_key(version), package["basename"])
            existing = chosen.get(name, None)
            if existing == None:
                chosen[name] = (key, len(packages))
                packages.append(package)
            elif key > existing[0]:
                dropped = packages[existing[1]]["basename"]
                packages[existing[1]] = package
                chosen[name] = (key, existing[1])
                conflict_message = "rules_mise: conda env '{env}' ({os_cpu}) installs {name} {version} instead of {dropped} (higher version)".format(
                    env = env_name,
                    os_cpu = os_cpu,
                    name = name,
                    version = version,
                    dropped = dropped,
                )
                print(conflict_message)  # buildifier: disable=print
    return packages

def _resolve_env_tools(env_name, specs, tools):
    """Maps an env's `tools` specs onto keys of the parsed lockfile tools.

    A spec is a mise tool name optionally suffixed with `@version`
    (`conda:postgresql@18.4`), matching how the same tool is written in
    `mise.toml`. Omitting the version requires the lockfile to pin exactly
    one, so an env can never silently pick between several.
    """
    keys = []
    for spec in specs:
        name, _, version = spec.rpartition("@")
        if not name:
            name, version = spec, ""

        matches = []
        for key, tool in tools.items():
            if tool["name"] == name and (not version or tool["version"] == version):
                matches.append(key)
        if not matches:
            fail("conda env '{env}': no tool '{spec}' in the lockfile".format(
                env = env_name,
                spec = spec,
            ))
        if len(matches) > 1:
            if not version:
                fail("conda env '{env}': tool '{name}' is locked at several versions ({versions}), pick one with '{name}@<version>'".format(
                    env = env_name,
                    name = name,
                    versions = ", ".join([tools[key]["version"] for key in matches]),
                ))
            fail("conda env '{env}': tool '{spec}' matches several lockfile entries ({keys})".format(
                env = env_name,
                spec = spec,
                keys = ", ".join(matches),
            ))
        if not tools[matches[0]]["backend"].startswith("conda:"):
            fail("conda env '{env}': tool '{spec}' uses the '{backend}' backend, only conda tools can share an environment".format(
                env = env_name,
                spec = spec,
                backend = tools[matches[0]]["backend"],
            ))
        keys.append(matches[0])
    return keys

def _env_binary(env_name, os, cpu, member_binaries):
    return {
        "os": os,
        "cpu": cpu,
        "url": "",
        "checksum": "",
        "kind": "conda_env",
        "version": "",
        "backend": "conda:env",
        "hint": env_name,
        "conda": {
            "packages": _merge_conda_packages(env_name, "{os}_{cpu}".format(os = os, cpu = cpu), member_binaries),
        },
    }

def _load_envs(envs, tools, lockfile):
    """Builds one synthetic tool definition per requested conda environment.

    A conda environment is exposed as a tool named `conda_env:<name>` (i.e.
    the `conda_env_<name>` Bazel key) so it gets the same targets as any other
    tool: `:tool`, `:cwd`, `:workspace_root` and a registered toolchain. The
    members' package closures are merged into a single `conda-prefix/`, which
    is the whole point: extensions such as pgvector are only loadable by a
    server sharing their prefix.
    """
    env_defs = {}
    for env in envs:
        env_name = env["name"]
        key = _clean("conda_env:" + env_name)
        if key in env_defs:
            fail("conda env '{env}' is declared more than once".format(env = env_name))
        members = _resolve_env_tools(env_name, env["tools"], tools)

        # A platform is only usable when every member provides it: an
        # environment missing one of its packages would install successfully
        # and then fail at runtime, which is far worse than not offering the
        # target at all.
        by_platform = {}
        for member in members:
            for binary in tools[member]["binaries"]:
                by_platform.setdefault((binary["os"], binary["cpu"]), []).append(binary)

        binaries = []
        for os_cpu in sorted(by_platform.keys()):
            member_binaries = by_platform[os_cpu]
            if len(member_binaries) != len(members):
                missing = []
                for member in members:
                    available = False
                    for binary in tools[member]["binaries"]:
                        if (binary["os"], binary["cpu"]) == os_cpu:
                            available = True
                    if not available:
                        missing.append(member)
                skip_message = "rules_mise: conda env '{env}' has no {os}_{cpu} build, skipping it ({tools} unavailable there)".format(
                    env = env_name,
                    os = os_cpu[0],
                    cpu = os_cpu[1],
                    tools = ", ".join(missing),
                )
                print(skip_message)  # buildifier: disable=print
                continue
            binaries.append(_env_binary(env_name, os_cpu[0], os_cpu[1], member_binaries))

        if not binaries:
            skip_message = "rules_mise: conda env '{env}' has no platform available from all of its tools in {lockfile}, skipping".format(
                env = env_name,
                lockfile = lockfile,
            )
            print(skip_message)  # buildifier: disable=print
            continue
        env_defs[key] = {
            "binaries": binaries,
            "version": env_name,
            "backend": "conda:env",
            "name": "conda_env:" + env_name,
        }
    return env_defs

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

def _load(ctx, lockfiles, envs = None):
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
                        # The unextended mise tool name (`conda:postgresql`),
                        # needed to resolve the specs of a conda env's members.
                        "name": tool_name,
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
    if envs:
        tools.update(_load_envs(envs, tools, ", ".join([str(lockfile) for lockfile in lockfiles])))
    return tools

def _sorted(tools):
    return sorted(tools.items())

lockfile = struct(
    load_defs = _load,
    sorted_defs = _sorted,
)
