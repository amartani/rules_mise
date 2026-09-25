load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_python//python:defs.bzl", "py_test")
load("@rules_python//python:pip.bzl", "compile_pip_requirements")
load(":postgres.bzl", "postgres_server")

postgres_server(
    name = "pg_server",
    tool = "@mise//tools/conda_postgresql:tool",
)

itest_service(
    name = "postgres",
    args = [
        "-p",
        "$${PORT}",
    ],
    autoassign_port = True,
    exe = ":pg_server",
    health_check = "@mise//tools/conda_postgresql:tool",
    health_check_args = [
        "pg_isready",
        "-h",
        "127.0.0.1",
        "-p",
        "$${PORT}",
        "-U",
        "postgres",
    ],
    visibility = ["//visibility:public"],
)

py_test(
    name = "_test_psql_no_services",
    srcs = ["test_psql_itest.py"],
    data = [
        "@mise//tools/conda_postgresql:tool",
    ],
    main = "test_psql_itest.py",
    tags = ["manual"],
    deps = [
        "@pypi//bazel_runfiles",
    ],
)

service_test(
    name = "test_psql",
    timeout = "moderate",
    env = {
        # buildifier: disable=canonical-repository
        "PGPORT": "$${@@//:postgres}",
    },
    services = [
        ":postgres",
    ],
    test = ":_test_psql_no_services",
)

compile_pip_requirements(
    name = "requirements",
    src = "requirements.in",
    requirements_txt = "requirements.txt",
)
