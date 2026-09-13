load("@rules_python//python:defs.bzl", "py_test")
load("@rules_python//python:pip.bzl", "compile_pip_requirements")

py_test(
    name = "test_psql",
    timeout = "moderate",
    srcs = ["test_psql.py"],
    data = [
        "@mise//tools/pkgx_postgresql.org:initdb",
        "@mise//tools/pkgx_postgresql.org:pg_ctl",
        "@mise//tools/pkgx_postgresql.org:pg_isready",
        "@mise//tools/pkgx_postgresql.org:psql",
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
