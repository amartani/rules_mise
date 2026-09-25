"mise hub repository"

load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "read_netrc", "read_user_netrc", "use_netrc")
load("//mise/private:lockfile.bzl", "lockfile")
load("//mise/private:templates.bzl", "templates")

def _get_auth(rctx, urls, auth_patterns):
    if "NETRC" in rctx.os.environ:
        netrc = read_netrc(rctx, rctx.os.environ["NETRC"])
    else:
        netrc = read_user_netrc(rctx)
    return use_netrc(netrc, urls, auth_patterns)

def _feature_sensitive_args(binary):
    args = {}
    if bazel_features.external_deps.download_has_headers_param:
        args["headers"] = binary.get("headers", {})
    return args

def _extension(os):
    return ".exe" if os == "windows" else ""

def _list_files(rctx, root):
    """Returns the sorted list of files under `root`, portably across OSes.

    `find` cannot be used here: on Windows it may resolve to
    C:\\Windows\\System32\\find.exe (a text search tool), which silently
    returns no matches. Matching happens in Starlark on the basenames.
    """
    if "windows" in rctx.os.name:
        # cmd.exe treats `/` as a switch introducer, so the path must use
        # backslashes (it is normalized back to `/` below).
        result = rctx.execute(["cmd.exe", "/c", "dir", "/s", "/b", "/a-d", root.replace("/", "\\")])
    else:
        result = rctx.execute(["find", root, "-type", "f"])
    if result.return_code != 0:
        fail("cannot list files under {root}: {err}".format(
            root = root,
            err = result.stderr,
        ))
    files = sorted([
        line.replace("\\", "/").strip()
        for line in result.stdout.splitlines()
        if line.strip()
    ])
    return files

def _match_rank(basename, tool_patterns, ext):
    """Ranks how well an archive member basename matches the tool.

    Returns (kind, index): kind 0 for an exact match (allowing the
    platform extension, e.g. `ruff` matching `ruff.exe`), kind 1 for a
    prefix match whose remainder carries no file extension (native
    executables conventionally have none, unlike bundled docs such as
    `yq.1`), kind 2 for any other prefix match, or None for no match.
    Lower ranks sort first.
    """
    for i, pattern in enumerate(tool_patterns):
        if basename == pattern or (ext and basename == pattern + ext):
            return (0, i)
    for i, pattern in enumerate(tool_patterns):
        if basename.startswith(pattern) and "." not in basename[len(pattern):]:
            return (1, i)
    for i, pattern in enumerate(tool_patterns):
        if basename.startswith(pattern):
            return (2, i)
    return None

def _download_extract_tool(rctx, tool_name, binary):
    # Entries without a checksum (e.g. `http:` backends) cannot be verified;
    # Bazel allows downloads without `sha256`, but the repo is then
    # non-reproducible.
    checksum_kwargs = {}
    if binary["checksum"]:
        checksum_kwargs["sha256"] = binary["checksum"]
    checksum_kwargs.update(_feature_sensitive_args(binary))
    reproducible = bool(binary["checksum"])

    os_cpu = "{os}_{cpu}".format(os = binary["os"], cpu = binary["cpu"])
    ext = _extension(binary["os"])
    target_filename = "{os_cpu}_executable{ext}".format(os_cpu = os_cpu, ext = ext)
    target_executable = "tools/{tool_name}/{target_filename}".format(
        tool_name = tool_name,
        target_filename = target_filename,
    )

    kind = binary["kind"]
    if kind == "file":
        rctx.download(
            url = binary["url"],
            output = target_executable,
            executable = True,
            auth = _get_auth(rctx, [binary["url"]], binary.get("auth_patterns", {})),
            **checksum_kwargs
        )
    elif kind == "archive":
        archive_path = "tools/{tool_name}/{os_cpu}_archive".format(
            tool_name = tool_name,
            os_cpu = os_cpu,
        )

        rctx.download_and_extract(
            url = binary["url"],
            output = archive_path,
            type = binary.get("type", ""),
            auth = _get_auth(rctx, [binary["url"]], binary.get("auth_patterns", {})),
            **checksum_kwargs
        )

        # Find the executable in the extracted archive. Tool names may carry
        # a backend prefix (e.g. `npm:prettier`), so try the trailing
        # segment first (see lockfile `hint`).
        tool_patterns = [tool_name, tool_name.replace("-", "_"), tool_name.replace("_", "-")]
        hint = binary.get("hint", "")
        if hint and hint != tool_name:
            hint_patterns = [hint, hint.replace("-", "_"), hint.replace("_", "-")]
            tool_patterns = hint_patterns + [p for p in tool_patterns if p not in hint_patterns]
        if binary.get("file"):
            archive_file = "{archive_path}/{file}".format(archive_path = archive_path, file = binary["file"])
            if not rctx.path(archive_file).exists:
                fail("{tool_name} ({os_cpu}): Cannot find {file} in archive from {url}".format(
                    tool_name = tool_name,
                    os_cpu = os_cpu,
                    file = binary["file"],
                    url = binary["url"],
                ))
            rctx.symlink(archive_file, target_executable)
        else:
            files = _list_files(rctx, archive_path)
            ranked = []
            for f in files:
                rank = _match_rank(f.rpartition("/")[2], tool_patterns, ext)
                if rank != None:
                    ranked.append((rank[0], rank[1], f))
            if ranked:
                found = sorted(ranked)[0][2]
            elif files:
                # No name match (e.g. the archive carries an unrelated
                # binary name): fall back to the first file, sorted for
                # determinism.
                found = files[0]
            else:
                found = None

            if not found:
                fail("{tool_name} ({os_cpu}): Cannot locate executable in archive from {url}".format(
                    tool_name = tool_name,
                    os_cpu = os_cpu,
                    url = binary["url"],
                ))
            rctx.symlink(found, target_executable)
    elif kind == "pkg":
        reproducible = False
        pkgutil_cmd = rctx.which("pkgutil")
        if not pkgutil_cmd:
            fail("{tool_name} ({os_cpu}): kind 'pkg' archives require macOS 'pkgutil' to expand, see {url}".format(
                tool_name = tool_name,
                os_cpu = os_cpu,
                url = binary["url"],
            ))

        archive_path = "tools/{tool_name}/{os_cpu}_pkg".format(
            tool_name = tool_name,
            os_cpu = os_cpu,
        )

        rctx.download(
            url = binary["url"],
            output = archive_path + ".pkg",
            auth = _get_auth(rctx, [binary["url"]], binary.get("auth_patterns", {})),
            **checksum_kwargs
        )

        rctx.execute([pkgutil_cmd, "--expand-full", archive_path + ".pkg", archive_path])

        archive_file = "{archive_path}/{file}".format(archive_path = archive_path, file = binary.get("file", ""))
        if not rctx.path(archive_file).exists:
            fail("{tool_name} ({os_cpu}): Cannot find {file} in pkg archive from {url}".format(
                tool_name = tool_name,
                os_cpu = os_cpu,
                file = binary["file"],
                url = binary["url"],
            ))
        rctx.symlink(archive_file, target_executable)
    else:
        fail("Unknown binary kind '{kind}' for {tool_name}".format(kind = kind, tool_name = tool_name))

    rctx.execute(["chmod", "+x", target_executable])

    # Generate the BUILD file for the tool repo
    rctx.file("tools/{}/BUILD.bazel".format(tool_name), """# Generated by mise
exports_files(["{target_filename}"])
""".format(target_filename = target_filename))

    return reproducible

def _tool_repo_impl(rctx):
    binary = json.decode(rctx.attr.binary)
    tool_name = rctx.attr.tool_name
    reproducible = _download_extract_tool(rctx, tool_name, binary)
    if not hasattr(rctx, "repo_metadata"):
        return None
    return rctx.repo_metadata(reproducible = reproducible)

tool_repo = repository_rule(
    attrs = {
        "tool_name": attr.string(mandatory = True),
        "binary": attr.string(mandatory = True),
    },
    implementation = _tool_repo_impl,
)

def _mise_hub_impl(rctx):
    tools = lockfile.load_defs(rctx, rctx.attr.lockfiles)

    # Generate hub-level files
    templates.hub(rctx, "toolchain_info.bzl", {
        "{hub_name}": rctx.attr.name,
    })

    # Root BUILD.bazel empty
    templates.hub(rctx, "BUILD.bazel", {})

    # tools/BUILD.bazel empty package
    templates.hub(rctx, "tools/BUILD.bazel", {})

    # Generate per-tool packages
    loads = []
    defines = []
    used_names = {}
    for tool_name, tool in lockfile.sorted_defs(tools):
        # Load aliases must be valid, unique Starlark identifiers; tool names
        # above may still contain `.` and `-` (and collide after sanitizing).
        base_name = tool_name.replace("-", "_").replace(".", "_")
        if base_name[:1] in "0123456789":
            base_name = "_" + base_name
        clean_name = base_name
        suffix = 2

        # No `while` in Starlark; at most len(used_names) candidates collide.
        for _ in range(len(used_names) + 1):
            if clean_name not in used_names:
                break
            clean_name = "{base}_{n}".format(base = base_name, n = suffix)
            suffix += 1
        used_names[clean_name] = True
        toolchain_lines = []
        for binary in tool["binaries"]:
            toolchain_lines.append(
                '    declare_toolchain(name="{name}", os="{os}", cpu="{cpu}", toolchain_type=_TOOLCHAIN_TYPE, hub_name="{hub_name}")'.format(
                    name = tool_name,
                    os = binary["os"],
                    cpu = binary["cpu"],
                    hub_name = rctx.name,
                ),
            )

        templates.hub_tool(rctx, tool_name, "tool.bzl", {
            "{toolchains}": "\n".join(toolchain_lines),
        })

        # Accumulate for toolchains package
        loads.append('load("//tools/{tool_name}:tool.bzl", declare_{clean_name}_toolchains = "declare_toolchains")'.format(
            tool_name = tool_name,
            clean_name = clean_name,
        ))
        defines.append("declare_{clean_name}_toolchains()".format(clean_name = clean_name))

        # Generate BUILD.bazel for this tool (without calling declare_toolchains)
        templates.hub_tool(rctx, tool_name, "BUILD.bazel", {})

    # Generate toolchains/BUILD.bazel
    templates.hub(rctx, "toolchains/BUILD.bazel", {
        "{loads}": "\n".join(loads),
        "{defines}": "\n".join(defines),
    })

    # Generate tools.bzl for non-bzlmod WORKSPACE usage
    templates.hub(rctx, "tools.bzl", templates.tools_substitutions(rctx.attr.name, tools))

    if not hasattr(rctx, "repo_metadata"):
        return None
    return rctx.repo_metadata(reproducible = True)

_mise_hub = repository_rule(
    attrs = {
        "lockfiles": attr.label_list(mandatory = True, allow_files = True),
    },
    implementation = _mise_hub_impl,
)

def bzlmod_hub(name, lockfiles, module_ctx):
    """Creates per-platform tool repos and the toolchain hub for bzlmod.

    Args:
        name: The name of the hub repository to create.
        lockfiles: Labels of the mise.lock files to parse.
        module_ctx: The module extension context.
    """
    tools = lockfile.load_defs(module_ctx, lockfiles)
    for tool_name, tool in lockfile.sorted_defs(tools):
        for binary in tool["binaries"]:
            os_cpu = "{os}_{cpu}".format(os = binary["os"], cpu = binary["cpu"])
            tool_repo(
                name = "{name}.{tool_name}.{os_cpu}".format(
                    name = name,
                    tool_name = tool_name,
                    os_cpu = os_cpu,
                ),
                tool_name = tool_name,
                binary = json.encode(binary),
            )
    _mise_hub(name = name, lockfiles = lockfiles)

def workspace_hub(name, lockfiles):
    """Creates the toolchain hub for WORKSPACE mode.

    Per-platform tool repos are created by calling `register_tools()`
    from `@<hub>//:tools.bzl` after this.

    Args:
        name: The name of the hub repository to create.
        lockfiles: Labels of the mise.lock files to parse.
    """
    _mise_hub(name = name, lockfiles = lockfiles)
