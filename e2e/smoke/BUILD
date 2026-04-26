genrule(
    name = "ruff_check",
    srcs = [
        ":test_sample.py",
        "@mise//tools/ruff:tool",
    ],
    outs = ["ruff_output.txt"],
    cmd = "$(location @mise//tools/ruff:tool) check $(location :test_sample.py) > $@ 2>&1 || true",
)
