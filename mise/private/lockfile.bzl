"Utilities for interacting with the mise lockfile."

load("@toml.bzl", "toml")

_MISE_PLATFORM_TO_BAZEL = {
    "linux-x64": struct(os = "linux", cpu = "x86_64"),
    "linux-arm64": struct(os = "linux", cpu = "aarch64"),
    "macos-x64": struct(os = "osx", cpu = "x86_64"),
    "macos-arm64": struct(os = "osx", cpu = "aarch64"),
    "windows-x64": struct(os = "windows", cpu = "x86_64"),
}

_MUSL_VARIANTS = {
    "linux-x64-musl": "linux-x64",
    "linux-arm64-musl": "linux-arm64",
}

def _parse_mise_platform(platform):
    if platform in _MUSL_VARIANTS:
        platform = _MUSL_VARIANTS[platform]
    if platform in _MISE_PLATFORM_TO_BAZEL:
        return _MISE_PLATFORM_TO_BAZEL[platform]
    return None

def _load(ctx, lockfiles):
    tools = {}
    for lockfile in lockfiles:
        parsed = toml.decode(ctx.read(lockfile))

        for tool_name, tool_data in parsed.items():
            if not tool_name.startswith("tools."):
                continue

            actual_name = tool_name[6:]
            if actual_name.startswith('"'):
                actual_name = actual_name[1:-1]

            if actual_name in tools:
                fail("Duplicate tool: {}".format(actual_name))

            binaries = []
            for platform_key, platform_data in tool_data.items():
                if not platform_key.startswith("platforms."):
                    continue

                platform = platform_key[9:]
                bazel_constraints = _parse_mise_platform(platform)
                if not bazel_constraints:
                    continue

                checksum = platform_data.get("checksum", "")
                if checksum.startswith("sha256:"):
                    checksum = checksum[7:]

                binaries.append({
                    "os": bazel_constraints.os,
                    "cpu": bazel_constraints.cpu,
                    "url": platform_data.get("url", ""),
                    "checksum": checksum,
                    "version": tool_data.get("version", ""),
                    "backend": tool_data.get("backend", ""),
                })

            if binaries:
                tools[actual_name] = {
                    "binaries": binaries,
                    "version": tool_data.get("version", ""),
                    "backend": tool_data.get("backend", ""),
                }

    return tools

def _sorted(tools):
    return sorted(tools.items())

lockfile = struct(
    load_defs = _load,
    sorted_defs = _sorted,
)
