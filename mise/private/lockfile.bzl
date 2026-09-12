"Utilities for interacting with the mise lockfile."

load("@toml.bzl", "toml")

_MISE_PLATFORM_TO_BAZEL = {
    "linux-arm64": struct(os = "linux", cpu = "arm64"),
    "linux-x64": struct(os = "linux", cpu = "x86_64"),
    "macos-arm64": struct(os = "macos", cpu = "arm64"),
    "macos-x64": struct(os = "macos", cpu = "x86_64"),
    "windows-x64": struct(os = "windows", cpu = "x86_64"),
}

_MUSL_VARIANTS = {
    "linux-x64-musl": "linux-x64",
    "linux-arm64-musl": "linux-arm64",
}

def _parse_mise_platform(platform):
    if platform in _MUSL_VARIANTS:
        return None
    if platform in _MISE_PLATFORM_TO_BAZEL:
        return _MISE_PLATFORM_TO_BAZEL[platform]
    return None

def _load(ctx, lockfiles):
    tools = {}
    for lockfile in lockfiles:
        parsed = toml.decode(ctx.read(lockfile))

        tools_dict = parsed.get("tools", {})
        for tool_name, tool_data in tools_dict.items():
            if type(tool_data) == "list":
                tool_entries = tool_data
            else:
                tool_entries = [tool_data]

            binaries = []
            version = ""
            backend = ""

            for tool_entry in tool_entries:
                if not version:
                    version = tool_entry.get("version", "")
                if not backend:
                    backend = tool_entry.get("backend", "")

                for platform_key, platform_data in tool_entry.items():
                    if not platform_key.startswith("platforms."):
                        continue

                    platform_suffix = platform_key[len("platforms."):]
                    bazel_constraints = _parse_mise_platform(platform_suffix)
                    if not bazel_constraints:
                        continue

                    url = platform_data.get("url", "")
                    checksum = platform_data.get("checksum", "")
                    if checksum.startswith("sha256:"):
                        checksum = checksum[7:]

                    if not url or not checksum:
                        continue

                    lower_url = url.lower()
                    if lower_url.endswith(".tar.gz") or lower_url.endswith(".tgz") or lower_url.endswith(".zip"):
                        kind = "archive"
                    elif lower_url.endswith(".pkg"):
                        kind = "pkg"
                    else:
                        kind = "file"

                    binary = {
                        "os": bazel_constraints.os,
                        "cpu": bazel_constraints.cpu,
                        "url": url,
                        "checksum": checksum,
                        "kind": kind,
                        "version": version,
                        "backend": backend,
                    }
                    binaries.append(binary)

            if binaries:
                tools[tool_name] = {
                    "binaries": binaries,
                    "version": version,
                    "backend": backend,
                }
    return tools

def _sorted(tools):
    return sorted(tools.items())

lockfile = struct(
    load_defs = _load,
    sorted_defs = _sorted,
)
