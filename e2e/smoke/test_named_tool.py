"""Test for the tool target named after its tool (`@mise//tools/ruff`).

Its executable keeps the tool's own basename, which binaries that dispatch on
argv[0] (such as mise itself) need.
"""

import os
import subprocess
import unittest

from runfiles import Runfiles

r = Runfiles.Create()


class NamedToolTest(unittest.TestCase):
    def test_named_tool_keeps_tool_basename(self):
        binary = r.Rlocation(os.environ["RUFF"])
        self.assertIsNotNone(binary, msg=f"missing runfile: {os.environ['RUFF']}")
        self.assertIn(os.path.basename(binary), ("ruff", "ruff.exe"))
        result = subprocess.run(
            [binary, "--version"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("ruff", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
