"mise private workspace_root execution rule"

load(":run_in.bzl", "run_in", "run_in_attrs")

def _workspace_root_impl(ctx):
    return run_in(ctx, "BUILD_WORKSPACE_DIRECTORY")

workspace_root = rule(
    doc = """An executable that runs its `tool` with the working directory set
to `$BUILD_WORKSPACE_DIRECTORY` (the workspace root). Exposed publicly by
`//mise:workspace_root.bzl`; see there for details.""",
    implementation = _workspace_root_impl,
    attrs = run_in_attrs,
    executable = True,
)
