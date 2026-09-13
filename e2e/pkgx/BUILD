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
    # pkgx bottles are built against a modern glibc (>= 2.25) but
    # BuildBuddy's default execution platform is Ubuntu 16.04 (glibc 2.23),
    # so run this test in an Ubuntu 22.04 container when executing remotely.
    exec_properties = {
        "container-image": "docker://ubuntu:22.04",
    },
    deps = [
        "@pypi//bazel_runfiles",
    ],
)

compile_pip_requirements(
    name = "requirements",
    src = "requirements.in",
    requirements_txt = "requirements.txt",
)
