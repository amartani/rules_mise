load("@rules_python//python:defs.bzl", "py_test")
load("@rules_python//python:pip.bzl", "compile_pip_requirements")

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
