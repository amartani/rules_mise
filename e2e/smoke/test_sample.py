import subprocess
import sys

from runfiles import Runfiles

r = Runfiles.Create()

ruff_binary = r.Rlocation("mise/tools/ruff/executable")

result = subprocess.run(
    [ruff_binary, "format", "--check", __file__], capture_output=True, text=True
)
print(result.stdout)
print(result.stderr)
sys.exit(result.returncode)
