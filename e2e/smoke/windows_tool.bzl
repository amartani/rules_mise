"""Builds a tool for Windows x86_64, whatever the host platform is."""

def _windows_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": str(Label("//:windows_x86_64"))}

_windows_transition = transition(
    implementation = _windows_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _windows_tool_impl(ctx):
    tool = ctx.attr.tool[0][DefaultInfo]
    return [DefaultInfo(files = tool.files, runfiles = tool.default_runfiles)]

windows_tool = rule(
    doc = "Forwards `tool` built for Windows x86_64, to check a cross build gets the Windows binary.",
    implementation = _windows_tool_impl,
    attrs = {
        "tool": attr.label(cfg = _windows_transition, mandatory = True),
    },
)
