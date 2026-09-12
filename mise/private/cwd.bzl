"mise private cwd execution rule"

load(":run_in.bzl", "run_in", "run_in_attrs")

def _cwd_impl(ctx):
    return run_in(ctx, "PWD")

cwd = rule(
    implementation = _cwd_impl,
    attrs = run_in_attrs,
    executable = True,
)
