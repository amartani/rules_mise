"""Extensions for bzlmod.

Provides hub extension for parsing mise.lock and exposing tools.
"""

load(":hub.bzl", "bzlmod_hub")

_DEFAULT_HUB_NAME = "mise"

hub = tag_class(
    attrs = {
        "hub_name": attr.string(default = _DEFAULT_HUB_NAME),
        "lockfile": attr.label(mandatory = True, allow_single_file = True),
    },
)

def _extension(module_ctx):
    lockfiles = {}
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

    # Ensure _DEFAULT_HUB_NAME is present in non-dev and dev deps when non-empty
    if root_module_direct_deps:
        root_module_direct_deps[_DEFAULT_HUB_NAME] = 1
    if root_module_direct_dev_deps:
        root_module_direct_dev_deps[_DEFAULT_HUB_NAME] = 1

    for hub_name, hub_lockfiles in lockfiles.items():
        bzlmod_hub(name = hub_name, lockfiles = hub_lockfiles, module_ctx = module_ctx)

    return module_ctx.extension_metadata(
        root_module_direct_deps = root_module_direct_deps.keys(),
        root_module_direct_dev_deps = root_module_direct_dev_deps.keys(),
        reproducible = True,
    )

mise = module_extension(
    implementation = _extension,
    tag_classes = {
        "hub": hub,
    },
)
