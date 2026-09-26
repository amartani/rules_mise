load("@rules_python//python:defs.bzl", "py_test")
load("@rules_python//python:pip.bzl", "compile_pip_requirements")

py_test(
    name = "test_psql_multi",
    timeout = "moderate",
    srcs = ["test_psql_multi.py"],
    data = [
        "@mise//tools/conda_postgresql_17.7:tool",
        "@mise//tools/conda_postgresql_18.4:tool",
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
