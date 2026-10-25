"""Extensions for bzlmod.

Provides the `mise` module extension for parsing `mise.lock` and exposing the
locked tools as Bazel repositories, toolchains, and executable targets.
"""

load(":hub.bzl", "bzlmod_hub")

_DEFAULT_HUB_NAME = "mise"

hub = tag_class(
    doc = """Reads a `mise.lock` and exposes its tools through a hub repository.

Several `hub` tags (from this or other modules) declaring the same `hub_name`
feed a single hub: every lockfile is parsed and its tools are merged there.
Tools become `@<hub_name>//tools/<sanitized name>:tool` targets plus `:cwd` and
`:workspace_root` wrappers, and `@<hub_name>//toolchains:all` must be
registered for toolchain resolution.""",
    attrs = {
        "hub_name": attr.string(
            doc = "Name of the hub repository to create (default `mise`).",
            default = _DEFAULT_HUB_NAME,
        ),
        "lockfile": attr.label(
            doc = "The `mise.lock` file to parse (single file).",
            mandatory = True,
            allow_single_file = True,
        ),
    },
)

conda_env = tag_class(
    doc = """Declares a merged conda environment exposed as a tool of its own.

Several conda tools (e.g. `conda:postgresql` plus `conda:pgvector`) are
installed into one shared conda prefix instead of one prefix per tool, which is
required when a package can only use files of the same prefix (PostgreSQL
extensions). The resulting tool is keyed `conda_env_<name>` with the same
targets as any other tool. Environments are attached to the `hub` tags in this
extension whose `lockfile` labels match, and every member tool must resolve in
that lockfile.""",
    attrs = {
        "name": attr.string(
            doc = "Name of the environment; the tool is exposed as `conda_env_<name>`.",
            mandatory = True,
        ),
        "lockfile": attr.label(
            doc = "The `mise.lock` file used to resolve the `tools` specs.",
            mandatory = True,
            allow_single_file = True,
        ),
        "tools": attr.string_list(
            doc = """Mise tool names with an optional `@version` suffix (e.g.
`conda:postgresql@18.4`), matching the tool names used in `mise.toml`.
Omitting `@version` requires the lockfile to pin exactly one version of that
tool. All members must use the `conda:` backend; other backends cannot share a
prefix.""",
            mandatory = True,
        ),
    },
)

def _extension(module_ctx):
    lockfiles = {}
    envs = {}
    root_module_direct_deps = {}
    root_module_direct_dev_deps = {}

    for mod in reversed(module_ctx.modules):
        for h in mod.tags.hub:
            if h.hub_name in lockfiles:
                lockfiles[h.hub_name].append(h.lockfile)
            else:
                lockfiles[h.hub_name] = [h.lockfile]

            if mod.is_root:
                if module_ctx.is_dev_dependency(h):
                    root_module_direct_dev_deps[h.hub_name] = 1
                else:
                    root_module_direct_deps[h.hub_name] = 1

        for e in mod.tags.conda_env:
            envs.setdefault(e.lockfile, []).append({
                "name": e.name,
                "tools": e.tools,
            })

    for hub_name, hub_lockfiles in lockfiles.items():
        # Environments are declared against a specific lockfile rather than a
        # hub, so they are collected across all hubs and attached to the ones
        # that read the same lockfile.
        hub_envs = []
        for lockfile in hub_lockfiles:
            hub_envs.extend(envs.get(lockfile, []))
        bzlmod_hub(
            name = hub_name,
            lockfiles = hub_lockfiles,
            envs = hub_envs,
            module_ctx = module_ctx,
        )

    return module_ctx.extension_metadata(
        root_module_direct_deps = root_module_direct_deps.keys(),
        root_module_direct_dev_deps = root_module_direct_dev_deps.keys(),
        reproducible = True,
    )

mise = module_extension(
    doc = """Exposes tools from a `mise.lock` as Bazel targets.

Declare at least one `hub` tag reading a `mise.lock`, `use_repo` the resulting
hub, and register `@<hub_name>//toolchains:all`. Optionally declare
`conda_env` tags to install several conda tools into one shared prefix.
Tools (and environments) resolve through toolchain selection, so the same
label picks the right binary for the platform it is built for.""",
    implementation = _extension,
    tag_classes = {
        "conda_env": conda_env,
        "hub": hub,
    },
)
