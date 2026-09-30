load("@rules_python//python:defs.bzl", "py_library", "py_test")
load("@rules_python//python:pip.bzl", "compile_pip_requirements")

py_library(
    name = "pg_test_lib",
    testonly = True,
    srcs = ["pg_test_lib.py"],
    deps = [
        "@pypi//bazel_runfiles",
    ],
)

py_test(
    name = "test_pgvector",
    size = "medium",
    srcs = ["test_pgvector.py"],
    data = [
        "@mise//tools/conda_env_pg:tool",
    ],
    deps = [
        ":pg_test_lib",
    ],
)

compile_pip_requirements(
    name = "requirements",
    src = "requirements.in",
    requirements_txt = "requirements.txt",
)
