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

# Subdirectories of a pkgx bottle prefix that back each runtime env var,
# mirroring mise's pkgx wrapper env composition (deps first, root last).
_PKGX_ENV_SUBDIRS = [
    ("PATH", ["bin", "sbin"]),
    ("MANPATH", ["share/man"]),
    ("PKG_CONFIG_PATH", ["lib/pkgconfig"]),
    ("LIBRARY_PATH", ["lib"]),
    ("LD_LIBRARY_PATH", ["lib"]),
    ("DYLD_FALLBACK_LIBRARY_PATH", ["lib"]),
    ("CPATH", ["include"]),
    ("XDG_DATA_DIRS", ["share"]),
]

def _shell_escape_double_quoted(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`")

def _normalize_rel(path):
    """Lexically normalizes a relative path (resolves `.` and `..`)."""
    parts = []
    for part in path.split("/"):
        if part == "" or part == ".":
            continue
        elif part == "..":
            if parts:
                parts.pop()
        else:
            parts.append(part)
    return "/".join(parts)

def _drop_cyclic_links(links):
    """Returns the subset of symlinks that must be dropped from the filegroup.

    `links` maps package-relative link paths to package-relative targets
    (absolute targets cannot cycle within the repo and are excluded upfront).
    A link is dropped when following it reaches a cycle: neither Bazel's
    glob nor runfiles tree creation can traverse those, so including them
    fails the build. Cyclic links are untraversable garbage for any
    tree-walking tool; everything else keeps working.
    """
    dropped = {}
    changed = True
    for _ in range(len(links) + 1):
        if not changed:
            break
        changed = False
        for start in links:
            if start in dropped:
                continue
            seen = {}
            node = start
            for _ in range(len(links) + 1):
                if node in dropped or node in seen:
                    dropped[start] = True
                    changed = True
                    break
                if node not in links:
                    break
                seen[node] = True
                node = links[node]
    return dropped

def _pkgx_prefix(pkg):
    # Bottles carry the full pkgx prefix layout (<project>/v<version>/...),
    # so extracting into pkgx-root reproduces mise's install layout exactly.
    # Returned paths are relative to pkgx-root.
    return "{name}/v{version}".format(name = pkg["name"], version = pkg["version"])

def _download_extract_pkgx(rctx, tool_name, binary, pkgx):
    """Installs a pkgx tool closure: main bottle plus transitive dependencies.

    Mirrors `mise install` from a lockfile: every bottle is extracted into the
    shared `pkgx-root/<package>/v<version>/` layout and a dispatcher script
    sets the pantry runtime environment (library paths, etc.) before exec'ing
    the requested binary, selected via argv[0] like mise's per-binary wrappers.
    """
    if binary["os"] == "windows":
        fail("pkgx tool {tool}: Windows is not supported yet".format(tool = tool_name))

    os_cpu = "{os}_{cpu}".format(os = binary["os"], cpu = binary["cpu"])
    dispatcher = "tools/{tool_name}/{os_cpu}_executable".format(tool_name = tool_name, os_cpu = os_cpu)

    # Bottles live next to the dispatcher so the package BUILD can list them.
    fs_root = "tools/{tool_name}/pkgx-root".format(tool_name = tool_name)

    provides = pkgx["provides"]
    if not provides:
        fail("pkgx tool {tool}: lockfile lists no provided binaries (pkgx_provides)".format(tool = tool_name))
    root_prefix = "pkgx-root/" + _pkgx_prefix(pkgx["packages"][-1])
    bins = {}
    for rel in provides:
        bins[rel.split("/")[-1]] = root_prefix + "/" + rel
    default_rel = root_prefix + "/" + provides[0]

    # Download and extract every bottle into the shared pkgx-root.
    for pkg in pkgx["packages"]:
        kwargs = {}
        if pkg["checksum"]:
            kwargs["sha256"] = pkg["checksum"]
        rctx.download_and_extract(
            url = pkg["url"],
            output = fs_root,
            auth = _get_auth(rctx, [pkg["url"]], binary.get("auth_patterns", {})),
            **kwargs
        )

    # Compose the runtime environment (deps first, root last), keeping only
    # subdirectories that actually exist in the extracted bottles.
    # The dispatcher may be reached via a symlink (the `tool` rule output),
    # so resolve to the real script directory (portable, no readlink -f).
    # Under remote execution that symlink may be materialized as a plain
    # file, leaving SCRIPT_DIR at the hub package instead of next to the
    # bottles (which live in this tool repo). Fall back to the runfiles
    # root plus this repo's runfiles path, both stable across machines.
    tool_runfiles_dir = "{repo}/tools/{tool}".format(repo = rctx.name, tool = tool_name)
    lines = [
        "#!/usr/bin/env bash",
        "_MISE_SOURCE=\"$0\"",
        "while [ -L \"$_MISE_SOURCE\" ]; do",
        "  _MISE_DIR=\"$(cd -P \"$(dirname \"$_MISE_SOURCE\")\" && pwd)\"",
        "  _MISE_SOURCE=\"$(readlink \"$_MISE_SOURCE\")\"",
        "  case \"$_MISE_SOURCE\" in",
        "    /*) ;;",
        "    *) _MISE_SOURCE=\"$_MISE_DIR/$_MISE_SOURCE\" ;;",
        "  esac",
        "done",
        "SCRIPT_DIR=\"$(cd -P \"$(dirname \"$_MISE_SOURCE\")\" && pwd)\"",
        "unset _MISE_SOURCE _MISE_DIR",
        "if [ ! -d \"$SCRIPT_DIR/pkgx-root\" ]; then",
        "  _MISE_ROOT=\"$SCRIPT_DIR\"",
        "  while [ \"$_MISE_ROOT\" != \"/\" ] && [ \"$_MISE_ROOT\" != \".\" ]; do",
        "    case \"$_MISE_ROOT\" in",
        "      *.runfiles) break ;;",
        "    esac",
        "    _MISE_ROOT=\"$(dirname \"$_MISE_ROOT\")\"",
        "  done",
        "  if [ -d \"$_MISE_ROOT/{runfiles_dir}/pkgx-root\" ]; then".format(runfiles_dir = tool_runfiles_dir),
        "    SCRIPT_DIR=\"$_MISE_ROOT/{runfiles_dir}\"".format(runfiles_dir = tool_runfiles_dir),
        "  fi",
        "  unset _MISE_ROOT",
        "fi",
    ]
    for (var, subdirs) in _PKGX_ENV_SUBDIRS:
        dirs = []
        for pkg in pkgx["packages"]:
            rel_prefix = _pkgx_prefix(pkg)
            for subdir in subdirs:
                if rctx.path(fs_root + "/" + rel_prefix + "/" + subdir).exists:
                    dirs.append("$SCRIPT_DIR/pkgx-root/" + rel_prefix + "/" + subdir)
        if dirs:
            lines.append('export {var}="{joined}${{{var}:+:${var}}}"'.format(var = var, joined = ":".join(dirs)))
    for pkg in pkgx["packages"]:
        prefix = "$SCRIPT_DIR/pkgx-root/" + _pkgx_prefix(pkg)
        for key in sorted(pkg["runtime_env"].keys()):
            value = pkg["runtime_env"][key]
            rendered = value.replace("{{prefix}}", prefix).replace("{{ prefix }}", prefix)
            if key in [var for (var, _) in _PKGX_ENV_SUBDIRS]:
                lines.append('export {key}="{value}${{{key}:+:${key}}}"'.format(
                    key = key,
                    value = _shell_escape_double_quoted(rendered),
                ))
            else:
                lines.append('export {key}="{value}"'.format(
                    key = key,
                    value = _shell_escape_double_quoted(rendered),
                ))

    # Dispatch on argv[0] so every provided binary shares one toolchain.
    lines.append('case "$(basename "$0")" in')
    for name in sorted(bins.keys()):
        lines.append('"{name}")'.format(name = name.replace('"', '\\"')))
        lines.append('exec "$SCRIPT_DIR/{rel}" "$@"'.format(rel = bins[name]))
        lines.append(";;")
    lines.append("*)")
    lines.append('exec "$SCRIPT_DIR/{rel}" "$@"'.format(rel = default_rel))
    lines.append(";;")
    lines.append("esac")
    rctx.file(dispatcher, "\n".join(lines) + "\n", executable = True)

    # List extracted files explicitly instead of globbing, and only files and
    # symlinks (never directories, which the runfiles tree would expand).
    # Bottles may contain symlink cycles (e.g. libxml2's
    # include/libxml2/libxml2 -> .); those links are dropped via
    # _drop_cyclic_links since no tree-walking tool can traverse them.
    # POSIX-only tooling (find/sh/readlink) so this also runs on macOS.
    listed = rctx.execute([
        "sh",
        "-c",
        'find "$1" -mindepth 1 \\( -type f -o -type l \\) -exec sh -c \'for f do if [ -L "$f" ]; then printf "l %s -> %s\\n" "$f" "$(readlink "$f")"; else printf "f %s\\n" "$f"; fi; done\' _ {} +',
        "_",
        fs_root,
    ])
    if listed.return_code != 0:
        fail("pkgx tool {tool}: cannot list {root}: {err}".format(
            tool = tool_name,
            root = fs_root,
            err = listed.stderr,
        ))

    # srcs are package-relative, so strip the "tools/<tool>/" prefix but keep
    # "pkgx-root/...".
    pkg_dir = "tools/{}/".format(tool_name)
    files = []
    links = {}
    dropped = {}
    for line in listed.stdout.splitlines():
        if line.startswith("l "):
            path, _, target = line[2:].rpartition(" -> ")
            path = path[len(pkg_dir):]
            if not target.startswith("/"):
                base = path.rpartition("/")[0]
                target = _normalize_rel(base + "/" + target if base else target)
                if path == target or path.startswith(target + "/"):
                    # Points at itself or an ancestor dir (e.g. `foo -> .`):
                    # traversing it re-enters its own subtree forever.
                    dropped[path] = True
                else:
                    links[path] = target
        elif line.startswith("f "):
            files.append(line[2:][len(pkg_dir):])
    for link in _drop_cyclic_links(links):
        dropped[link] = True
    srcs = "\n".join([
        '        "{path}",'.format(
            path = path.replace("\\", "\\\\").replace('"', '\\"'),
        )
        for path in sorted(files + [link for link in links if link not in dropped])
    ])

    rctx.file("tools/{}/BUILD.bazel".format(tool_name), """# Generated by mise
exports_files(["{target_filename}"])

filegroup(
    name = "pkgx_files",
    srcs = [
{srcs}
        "{target_filename}",
    ],
    visibility = ["//visibility:public"],
)
""".format(
        target_filename = "{os_cpu}_executable".format(os_cpu = os_cpu),
        srcs = srcs,
    ))

    return True

def _download_extract_tool(rctx, tool_name, binary):
    reproducible = True
    if "pkgx" in binary:
        return _download_extract_pkgx(rctx, tool_name, binary, binary["pkgx"])

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
            sha256 = binary["checksum"],
            output = target_executable,
            executable = True,
            auth = _get_auth(rctx, [binary["url"]], binary.get("auth_patterns", {})),
            **_feature_sensitive_args(binary)
        )
    elif kind == "archive":
        archive_path = "tools/{tool_name}/{os_cpu}_archive".format(
            tool_name = tool_name,
            os_cpu = os_cpu,
        )

        rctx.download_and_extract(
            url = binary["url"],
            sha256 = binary["checksum"],
            output = archive_path,
            type = binary.get("type", ""),
            auth = _get_auth(rctx, [binary["url"]], binary.get("auth_patterns", {})),
            **_feature_sensitive_args(binary)
        )

        # Find the executable in the extracted archive
        tool_patterns = [tool_name, tool_name.replace("-", "_"), tool_name.replace("_", "-")]
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
            found = None
            for pattern in tool_patterns:
                result = rctx.execute(["find", archive_path, "-name", pattern, "-type", "f"])
                if result.stdout and result.stdout.strip():
                    found = result.stdout.strip().split("\n")[0]
                    break
                result = rctx.execute(["find", archive_path, "-name", pattern + "*", "-type", "f"])
                if result.stdout and result.stdout.strip():
                    found = result.stdout.strip().split("\n")[0]
                    break

            if not found:
                result = rctx.execute(["find", archive_path, "-type", "f", "-perm", "-u=x"])
                if result.stdout and result.stdout.strip():
                    found = result.stdout.strip().split("\n")[0]

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
            return reproducible

        archive_path = "tools/{tool_name}/{os_cpu}_pkg".format(
            tool_name = tool_name,
            os_cpu = os_cpu,
        )

        rctx.download(
            url = binary["url"],
            sha256 = binary["checksum"],
            output = archive_path + ".pkg",
            auth = _get_auth(rctx, [binary["url"]], binary.get("auth_patterns", {})),
            **_feature_sensitive_args(binary)
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

filegroup(
    name = "pkgx_files",
    srcs = [],
    visibility = ["//visibility:public"],
)
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
    for tool_name, tool in lockfile.sorted_defs(tools):
        # Load aliases must be valid Starlark identifiers; paths/labels above
        # may still contain `.` and `-`.
        clean_name = tool_name.replace("-", "_").replace(".", "_")
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

        # pkgx tools expose one target per provided binary (all sharing the
        # dispatcher toolchain); other tools expose just ":tool".
        extra_targets = []
        for rel in tool.get("provides", []):
            bin_name = rel.split("/")[-1]
            if bin_name and bin_name != "tool" and bin_name not in extra_targets:
                extra_targets.append(bin_name)

        tool_bzl_content = """# Generated by mise

load("//:toolchain_info.bzl", "declare_toolchain")

_TOOLCHAIN_TYPE = "//tools/{name}:toolchain_type"

def _tool_impl(ctx):
    toolchain = ctx.toolchains[_TOOLCHAIN_TYPE]
    output = ctx.actions.declare_file(ctx.label.name + toolchain.ext)
    ctx.actions.symlink(output = output, target_file = toolchain.executable)
    runfiles = ctx.runfiles(files = [output] + toolchain.files)
    return [DefaultInfo(executable = output, runfiles = runfiles)]

tool = rule(executable = True, implementation = _tool_impl, toolchains = [_TOOLCHAIN_TYPE])

def declare_toolchains():
{toolchains}
"""
        rctx.file("tools/{}/tool.bzl".format(tool_name), tool_bzl_content.format(
            name = tool_name,
            toolchains = "\n".join(toolchain_lines),
        ))

        # Accumulate for toolchains package
        loads.append('load("//tools/{tool_name}:tool.bzl", declare_{clean_name}_toolchains = "declare_toolchains")'.format(
            tool_name = tool_name,
            clean_name = clean_name,
        ))
        defines.append("declare_{clean_name}_toolchains()".format(clean_name = clean_name))

        # Generate BUILD.bazel for this tool (without calling declare_toolchains)
        extra_tools = "".join([
            """
tool(
    name = "{bin_name}",
    visibility = ["//visibility:public"],
)
""".format(bin_name = bin_name)
            for bin_name in extra_targets
        ])
        build_content = """# Generated by mise

load("@rules_mise//mise/private:cwd.bzl", "cwd")
load("@rules_mise//mise/private:workspace_root.bzl", "workspace_root")
load(":tool.bzl", "tool")

toolchain_type(
    name = "toolchain_type",
    visibility = ["//:__subpackages__"],
)

tool(
    name = "tool",
    visibility = ["//visibility:public"],
)
{extra_tools}
cwd(
    name = "cwd",
    tool = ":tool",
    visibility = ["//visibility:public"],
)

workspace_root(
    name = "workspace_root",
    tool = ":tool",
    visibility = ["//visibility:public"],
)

"""
        rctx.file("tools/{}/BUILD.bazel".format(tool_name), build_content.format(extra_tools = extra_tools))

    # Generate toolchains/BUILD.bazel
    toolchains_build = """# Generated by mise

{loads}

{defines}
"""
    rctx.file("toolchains/BUILD.bazel", toolchains_build.format(
        loads = "\n".join(loads),
        defines = "\n".join(defines),
    ))

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
