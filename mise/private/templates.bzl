"mise templating"

load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")

_HUB_TEMPLATE = "//mise/private:hub_repo_template/{filename}.template"
_HUB_TOOL_TEMPLATE = "//mise/private:hub_repo_tool_template/{filename}.template"

_HOST_CONSTRAINTS_MAPPING = {
    "@platforms//cpu:aarch64": "arm64",
    "@platforms//cpu:arm64": "arm64",
    "@platforms//cpu:x86_64": "x86_64",
    "@platforms//os:osx": "macos",
    "@platforms//os:macos": "macos",
    "@platforms//os:linux": "linux",
    "@platforms//os:windows": "windows",
}

# Other targets of every tool package; a tool with one of these names keeps
# `tool` as its main target name.
_RESERVED_TARGET_NAMES = ["tool", "cwd", "workspace_root", "toolchain_type"]

# TODO: Remove `:tool` once its users have moved to `:<tool>`.
_TOOL_ALIAS = """
alias(
    name = "tool",
    actual = ":{main_target}",
    visibility = ["//visibility:public"],
)
"""

def _main_target(tool_name):
    """Returns the name of a tool package's main target.

    The target is named after the tool so that its executable keeps the tool's
    own basename, which binaries dispatching on `argv[0]` (such as mise
    itself) require.
    """
    if tool_name in _RESERVED_TARGET_NAMES:
        return "tool"
    return tool_name

def _main_target_subs(tool_name):
    main_target = _main_target(tool_name)
    return {
        "{main_target}": main_target,
        "{tool_alias}": _TOOL_ALIAS.format(main_target = main_target) if main_target != "tool" else "",
    }

def _render_hub(rctx, filename, substitutions = None):
    rctx.template(
        filename,
        Label(_HUB_TEMPLATE.format(filename = filename)),
        substitutions = substitutions or {},
    )

def _render_hub_tool(rctx, tool_name, filename, substitutions = None):
    rctx.template(
        "tools/{tool_name}/{filename}".format(tool_name = tool_name, filename = filename),
        Label(_HUB_TOOL_TEMPLATE.format(filename = filename)),
        substitutions = {
            "{name}": tool_name,
        } | (substitutions or {}),
    )

def _render_tool_labels(tools):
    supported_host_constraints = [_HOST_CONSTRAINTS_MAPPING.get(constraint, None) for constraint in HOST_CONSTRAINTS]
    host_tool_keys = []
    for tool_key, tool in tools.items():
        for binary in tool.get("binaries", []):
            if binary["os"] in supported_host_constraints and binary["cpu"] in supported_host_constraints:
                if tool_key not in host_tool_keys:
                    host_tool_keys.append(tool_key)
                break
    return "".join([
        '    "{tool_name}": Label("//tools/{tool_name}:{target}"),\n'.format(
            tool_name = tool_name,
            target = _main_target(tool_name),
        )
        for tool_name in host_tool_keys
    ])

def _render_tool_repo_def(hub_name, tool_name, binary):
    os_cpu = "{os}_{cpu}".format(os = binary["os"], cpu = binary["cpu"])
    name = "{name}.{tool_name}.{os_cpu}".format(
        name = hub_name,
        tool_name = tool_name,
        os_cpu = os_cpu,
    )
    return """    tool_repo(
        name = "{name}",
        tool_name = "{tool_name}",
        binary = '{binary}',
    )

""".format(
        name = name,
        tool_name = tool_name,
        binary = json.encode(binary),
    )

def _render_tool_repo_defs(hub_name, tools):
    if len(tools) == 0:
        return "    pass\n"
    result = []
    for tool_name, tool in tools.items():
        for binary in tool.get("binaries", []):
            result.append(_render_tool_repo_def(hub_name, tool_name, binary))
    return "".join(result)

def _tools_subs(hub_name, tools):
    return {
        "{tool_labels}": _render_tool_labels(tools),
        "{tool_repos}": _render_tool_repo_defs(hub_name, tools),
    }

templates = struct(
    hub = _render_hub,
    hub_tool = _render_hub_tool,
    main_target_substitutions = _main_target_subs,
    tools_substitutions = _tools_subs,
)
