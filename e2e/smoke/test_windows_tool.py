import sys

from runfiles import Runfiles

r = Runfiles.Create()

# Without `.exe`, or without the PE header, toolchain resolution picked the
# host's binary instead of the Windows target's.
ruff_binary = r.Rlocation("mise/tools/ruff/tool.exe")
if ruff_binary is None:
    sys.exit("mise/tools/ruff/tool.exe is not in runfiles")

with open(ruff_binary, "rb") as f:
    magic = f.read(2)
if magic != b"MZ":
    sys.exit(f"{ruff_binary} is not a Windows executable: starts with {magic!r}")
