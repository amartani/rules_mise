"mise run_in provides a shared implementation for cwd and workspace_root execution"

run_in_attrs = {
    "tool": attr.label(
        doc = "The wrapped tool executable (typically a hub `tool` target).",
        mandatory = True,
        executable = True,
        cfg = "exec",
    ),
    "_template_sh": attr.label(default = "//mise/private:run_in.template.sh", allow_single_file = True),
    "_template_bat": attr.label(default = "//mise/private:run_in.template.bat", allow_single_file = True),
}

def run_in(ctx, env_var):
    """Expands the run_in wrapper script for a tool (shared by `cwd` and `workspace_root`).

    Renders `run_in.template.sh` (or `run_in.template.bat` when the tool output
    is a `.exe`, Windows-only) with the wrapped tool's short path and the name
    of the env var holding the desired working directory (the wrapper stays in
    the current directory when it is unset), and publish the wrapper as the
    rule's executable with the tool's runfiles attached.

    Args:
        ctx: The rule context. Must provide `tool`, `_template_sh`, and `_template_bat`.
        env_var: The environment variable the wrapper sets to the execution directory.

    Returns:
        A list containing the DefaultInfo for the wrapper executable.
    """
    template = ctx.file._template_sh
    wrapper_name = ctx.label.name
    tool_file = ctx.executable.tool
    tool_short_path = tool_file.short_path

    # In the runfiles tree, external repository files live at their short
    # path without the leading `../` (e.g. `../repo/path` -> `repo/path`).
    if tool_short_path.startswith("../"):
        tool_runfiles_path = tool_short_path[3:]
    else:
        tool_runfiles_path = tool_short_path
    tool_filename = tool_file.basename
    if tool_file.extension == "exe":
        template = ctx.file._template_bat
        wrapper_name = wrapper_name + ".bat"
        tool_short_path = tool_short_path.replace("/", "\\")
    output = ctx.actions.declare_file(wrapper_name)
    ctx.actions.expand_template(
        template = template,
        output = output,
        substitutions = {
            "{{tool}}": tool_short_path,
            "{{tool_filename}}": tool_filename,
            "{{runfiles_path}}": tool_runfiles_path,
            "{{env_var}}": env_var,
        },
    )
    runfiles = ctx.runfiles(files = ctx.files.tool)
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = output, runfiles = runfiles)]
