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

def _download_extract_conda(rctx, tool_name, binary, conda):
    """Installs a conda tool closure: main package plus transitive dependencies.

    Mirrors `mise install` from a lockfile: every package is extracted into the
    shared `conda-prefix/` layout and a dispatcher script sets the conda
    runtime environment (`CONDA_PREFIX`, `PATH`, activation scripts) before
    exec'ing the requested binary, selected via argv[0] or via the first
    argument (so a single `:tool` target can run any binary in the prefix).

    `.conda` packages are zipped `tar.zst` archives: the outer zip is extracted
    with Bazel's built-in zip support, then the inner `pkg-*.tar.zst` with
    Bazel's built-in `tar.zst` support (available in Bazel 8+). `.tar.bz2`
    packages (old conda format) are extracted directly. Prefix-placeholder
    replacement is skipped: postgres binaries are relocatable via `$ORIGIN`
    RPATH and locate their `share/` files relative to the binary.
    """
    if binary["os"] == "windows":
        fail("conda tool {tool}: Windows is not supported yet".format(tool = tool_name))

    os_cpu = "{os}_{cpu}".format(os = binary["os"], cpu = binary["cpu"])
    dispatcher = "tools/{tool_name}/{os_cpu}_executable".format(tool_name = tool_name, os_cpu = os_cpu)
    fs_root = "tools/{tool_name}/conda-prefix".format(tool_name = tool_name)

    reproducible = True
    for pkg in conda["packages"]:
        url = pkg["url"]
        checksum = pkg["checksum"]
        basename = pkg["basename"]
        if not url:
            fail("conda tool {tool}: missing url for package {basename}".format(
                tool = tool_name,
                basename = basename,
            ))
        kwargs = {}
        if checksum:
            kwargs["sha256"] = checksum
        else:
            reproducible = False
        kwargs.update(_feature_sensitive_args(binary))
        lower_url = url.lower()
        if lower_url.endswith(".conda"):
            zip_path = "tools/{tool_name}/downloads/{basename}.zip".format(
                tool_name = tool_name,
                basename = basename,
            )
            rctx.download(
                url = url,
                output = zip_path,
                auth = _get_auth(rctx, [url], binary.get("auth_patterns", {})),
                **kwargs
            )
            outer_dir = "tools/{tool_name}/outer/{basename}".format(
                tool_name = tool_name,
                basename = basename,
            )
            rctx.extract(zip_path, output = outer_dir)
            inner = "{outer}/pkg-{basename}.tar.zst".format(
                outer = outer_dir,
                basename = basename,
            )
            if not rctx.path(inner).exists:
                fail("conda tool {tool}: cannot find pkg archive {inner} in {url}".format(
                    tool = tool_name,
                    inner = inner,
                    url = url,
                ))
            rctx.extract(inner, output = fs_root)
        elif lower_url.endswith(".tar.bz2"):
            rctx.download_and_extract(
                url = url,
                output = fs_root,
                auth = _get_auth(rctx, [url], binary.get("auth_patterns", {})),
                **kwargs
            )

            # Old-format packages ship an `info/` directory which must not
            # pollute the shared prefix (and would collide across packages).
            rctx.execute(["rm", "-rf", fs_root + "/info"])
        else:
            fail("conda tool {tool}: unsupported package URL {url} (expected .conda or .tar.bz2)".format(
                tool = tool_name,
                url = url,
            ))

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
        "if [ ! -d \"$SCRIPT_DIR/conda-prefix\" ]; then",
        "  _MISE_ROOT=\"$SCRIPT_DIR\"",
        "  while [ \"$_MISE_ROOT\" != \"/\" ] && [ \"$_MISE_ROOT\" != \".\" ]; do",
        "    case \"$_MISE_ROOT\" in",
        "      *.runfiles) break ;;",
        "    esac",
        "    _MISE_ROOT=\"$(dirname \"$_MISE_ROOT\")\"",
        "  done",
        "  if [ -d \"$_MISE_ROOT/{runfiles_dir}/conda-prefix\" ]; then".format(runfiles_dir = tool_runfiles_dir),
        "    SCRIPT_DIR=\"$_MISE_ROOT/{runfiles_dir}\"".format(runfiles_dir = tool_runfiles_dir),
        "  fi",
        "  unset _MISE_ROOT",
        "fi",
        "export CONDA_PREFIX=\"$SCRIPT_DIR/conda-prefix\"",
        "export CONDA_DEFAULT_ENV=\"$CONDA_PREFIX\"",
        "export CONDA_SHLVL=1",
        "export PATH=\"$CONDA_PREFIX/bin:$CONDA_PREFIX/sbin${PATH:+:$PATH}\"",
        "for _mise_conda_script in \"$CONDA_PREFIX\"/etc/conda/activate.d/*.sh; do",
        "  if [ -f \"$_mise_conda_script\" ]; then",
        "    . \"$_mise_conda_script\" || exit $?",
        "  fi",
        "done",
        "unset _mise_conda_script",
        "_MISE_BIN=\"$(basename \"$0\")\"",
        "if [ \"$_MISE_BIN\" != \"tool\" ] && [ -x \"$CONDA_PREFIX/bin/$_MISE_BIN\" ]; then",
        "  exec \"$CONDA_PREFIX/bin/$_MISE_BIN\" \"$@\"",
        "fi",
        "if [ \"$_MISE_BIN\" != \"tool\" ] && [ -x \"$CONDA_PREFIX/sbin/$_MISE_BIN\" ]; then",
        "  exec \"$CONDA_PREFIX/sbin/$_MISE_BIN\" \"$@\"",
        "fi",
        "unset _MISE_BIN",
        "if [ $# -gt 0 ]; then",
        "  exec \"$@\"",
        "fi",
        "echo \"conda tool wrapper: no command given\" >&2",
        "exit 1",
    ]
    rctx.file(dispatcher, "\n".join(lines) + "\n", executable = True)

    # List extracted files explicitly instead of globbing, and only files and
    # symlinks (never directories, which the runfiles tree would expand).
    # Bottles may contain symlink cycles; those links are dropped via
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
        fail("conda tool {tool}: cannot list {root}: {err}".format(
            tool = tool_name,
            root = fs_root,
            err = listed.stderr,
        ))

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
    name = "conda_files",
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

    return reproducible

def _download_extract_tool(rctx, tool_name, binary):
    # Entries without a checksum (e.g. `http:` backends) cannot be verified;
    # Bazel allows downloads without `sha256`, but the repo is then
    # non-reproducible.
    checksum_kwargs = {}
    if binary["checksum"]:
        checksum_kwargs["sha256"] = binary["checksum"]
    checksum_kwargs.update(_feature_sensitive_args(binary))
    reproducible = bool(binary["checksum"])
    if "conda" in binary:
        return _download_extract_conda(rctx, tool_name, binary, binary["conda"])

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

filegroup(
    name = "conda_files",
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
