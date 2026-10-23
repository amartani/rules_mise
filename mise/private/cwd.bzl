"mise private cwd execution rule"

load(":run_in.bzl", "run_in", "run_in_attrs")

def _cwd_impl(ctx):
    return run_in(ctx, "PWD")

cwd = rule(
    doc = """An executable that runs its `tool` with the working directory set
to `$PWD` (Bazel's client working directory). Exposed publicly by
`//mise:cwd.bzl`; see there for details.""",
    implementation = _cwd_impl,
    attrs = run_in_attrs,
    executable = True,
)
