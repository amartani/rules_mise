"mise templating"

load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")

_HUB_TEMPLATE = "//mise/private:hub_repo_template/{filename}.template"
_HUB_TOOL_TEMPLATE = "//mise/private:hub_repo_tool_template/{filename}.template"

_TOOL_REPO_TEMPLATE = "//mise/private:tool_repo_template/{filename}.template"
_TOOL_REPO_TOOL_TEMPLATE = "//mise/private:tool_repo_tool_template/{filename}.template"

_HOST_CONSTRAINTS_MAPPING = {
    "@platforms//cpu:aarch64": "arm64",
    "@platforms//cpu:arm64": "arm64",
    "@platforms//cpu:x86_64": "x86_64",
    "@platforms//os:osx": "macos",
    "@platforms//os:macos": "macos",
    "@platforms//os:linux": "linux",
    "@platforms//os:windows": "windows",
}

def _render_tool_repo(rctx, filename, substitutions = None):
    rctx.template(
        filename,
        Label(_TOOL_REPO_TEMPLATE.format(filename = filename)),
        substitutions = substitutions or {},
    )

def _render_tool_repo_tool(rctx, tool_name, filename, substitutions = None):
    rctx.template(
        "tools/{tool_name}/{filename}".format(tool_name = tool_name, filename = filename),
        Label(_TOOL_REPO_TOOL_TEMPLATE.format(filename = filename)),
        substitutions = {
            "{name}": tool_name,
        } | (substitutions or {}),
    )

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
        '    "{tool_name}": Label("//tools/{tool_name}"),\n'.format(tool_name = tool_name)
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
    tool_repo = _render_tool_repo,
    tool_repo_tool = _render_tool_repo_tool,
    tools_substitutions = _tools_subs,
)
