load("@rules_python//python:defs.bzl", "py_test")
load("@rules_python//python:pip.bzl", "compile_pip_requirements")

py_test(
    name = "test_opensearch",
    size = "large",
    timeout = "long",
    srcs = ["test_opensearch.py"],
    data = [
        "@mise//tools/conda_opensearch:tool",
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
