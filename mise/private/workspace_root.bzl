"mise private workspace_root execution rule"

load(":run_in.bzl", "run_in", "run_in_attrs")

def _workspace_root_impl(ctx):
    return run_in(ctx, "BUILD_WORKSPACE_DIRECTORY")

workspace_root = rule(
    implementation = _workspace_root_impl,
    attrs = run_in_attrs,
    executable = True,
)
