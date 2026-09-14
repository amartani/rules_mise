"mise run_in provides a shared implementation for cwd and workspace_root execution"

run_in_attrs = {
    "tool": attr.label(mandatory = True, executable = True, cfg = "exec"),
    "_template_sh": attr.label(default = "//mise/private:run_in.template.sh", allow_single_file = True),
    "_template_bat": attr.label(default = "//mise/private:run_in.template.bat", allow_single_file = True),
}

def run_in(ctx, env_var):
    """Expands the run_in wrapper script for a tool.

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
