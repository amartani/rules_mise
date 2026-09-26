load("@rules_python//python:defs.bzl", "py_test")
load("@rules_python//python:pip.bzl", "compile_pip_requirements")

py_test(
    name = "test_backends",
    srcs = ["test_backends.py"],
    data = [
        "@mise//tools/aqua_mikefarah_yq:tool",
        "@mise//tools/bun:tool",
        "@mise//tools/forgejo_gitea_tea:tool",
        "@mise//tools/github_mikefarah_yq:tool",
        "@mise//tools/gitlab_gitlab-org_release-cli:tool",
        "@mise//tools/http_yq:tool",
        "@mise//tools/http_yq_blake3:tool",
        "@mise//tools/packslip_github.com_jdx_hk:tool",
        "@mise//tools/ruff:tool",
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
