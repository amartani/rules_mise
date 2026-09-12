import subprocess
import sys

from runfiles import Runfiles

r = Runfiles.Create()

jq_binary = r.Rlocation("mise/tools/pkgx_stedolan.github.io_jq/jq")


def run(args, input=None):
    result = subprocess.run(
        [jq_binary] + args, input=input, capture_output=True, text=True
    )
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        sys.exit(result.returncode)
    return result.stdout


# The tool itself works.
version = run(["--version"])
assert "jq-" in version, "unexpected jq version output: %r" % version

# Regex support is provided by the oniguruma dependency at runtime.
assert run(["test(\"[0-9]+\")"], input='"abc123"').strip() == "true"

# The launcher wires the pkgx dependency closure into the environment.
ld_library_path = run(["-n", "$ENV.LD_LIBRARY_PATH"]).strip()
assert "pkgx-root" in ld_library_path, (
    "pkgx dependency lib dirs missing from LD_LIBRARY_PATH: %r" % ld_library_path
)
