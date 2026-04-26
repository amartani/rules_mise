"""Extensions for bzlmod.

Provides hub extension for parsing mise.lock and exposing tools.
"""

load(":hub.bzl", "bzlmod_hub")

hub = tag_class(attrs = {
    "hub_name": attr.string(default = "mise"),
    "lockfile": attr.label(mandatory = True, allow_single_file = True),
})

def _toolchain_extension(module_ctx):
    hub_name = None
    hub_lockfiles = []

    for mod in module_ctx.modules:
        for h in mod.tags.hub:
            if hub_name and hub_name != h.hub_name:
                fail("Multiple hub names not supported: {} and {}".format(hub_name, h.hub_name))
            hub_name = h.hub_name
            hub_lockfiles.append(h.lockfile)

    if hub_lockfiles:
        bzlmod_hub(
            name = hub_name or "mise",
            lockfiles = hub_lockfiles,
            module_ctx = module_ctx,
        )
        return module_ctx.extension_metadata(
            root_module_direct_deps = [hub_name],
            root_module_direct_dev_deps = [],
            reproducible = True,
        )

    return module_ctx.extension_metadata(
        reproducible = True,
    )

mise = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {
        "hub": hub,
    },
    os_dependent = False,
    arch_dependent = False,
)
