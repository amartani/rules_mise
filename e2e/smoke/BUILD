load("@rules_python//python:defs.bzl", "py_test")
load("@rules_python//python:pip.bzl", "compile_pip_requirements")
load(":windows_tool.bzl", "windows_tool")

py_test(
    name = "test_sample",
    srcs = ["test_sample.py"],
    data = [
        "@mise//tools/ruff:tool",
    ],
    deps = [
        "@pypi//bazel_runfiles",
    ],
)

py_test(
    name = "test_named_tool",
    srcs = ["test_named_tool.py"],
    data = [
        "@mise//tools/ruff",
    ],
    env = {
        "RUFF": "$(rlocationpath @mise//tools/ruff)",
    },
    deps = [
        "@pypi//bazel_runfiles",
    ],
)

py_test(
    name = "test_cwd_wrapper",
    srcs = ["test_cwd_wrapper.py"],
    data = [
        "@mise//tools/ruff:cwd",
        "@mise//tools/ruff:workspace_root",
    ],
    deps = [
        "@pypi//bazel_runfiles",
    ],
)

compile_pip_requirements(
    name = "requirements",
    src = "requirements.in",
    requirements_txt = "requirements.txt",
)

genrule(
    name = "ruff_check",
    srcs = [
        ":test_sample.py",
        "@mise//tools/ruff:tool",
    ],
    outs = ["ruff_output.txt"],
    cmd = "$(execpath @mise//tools/ruff:tool) check $(execpath :test_sample.py) > $@ 2>&1 || true",
)

platform(
    name = "windows_x86_64",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:windows",
    ],
)

windows_tool(
    name = "ruff_windows",
    tool = "@mise//tools/ruff",
)

py_test(
    name = "test_windows_tool",
    srcs = ["test_windows_tool.py"],
    data = [":ruff_windows"],
    deps = [
        "@pypi//bazel_runfiles",
    ],
)
