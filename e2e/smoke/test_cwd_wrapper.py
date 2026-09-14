"""Direct-execution test for the :cwd and :workspace_root tool wrappers.

The wrappers must resolve the wrapped tool without depending on Bazel's
launch working directory (see run_in.template.sh): they are executed here
straight from the runfiles tree with an unrelated cwd, which `bazel run`
would otherwise mask.
"""

import os
import subprocess
import tempfile
import unittest

from runfiles import Runfiles

r = Runfiles.Create()


def rlocation(path):
    resolved = r.Rlocation(path)
    assert resolved is not None, f"missing runfile: {path}"
    return resolved


class WrapperTest(unittest.TestCase):
    def test_cwd_runs_tool_directly(self):
        cwd = rlocation("mise/tools/ruff/cwd")
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [cwd, "--version"],
                capture_output=True,
                text=True,
                check=False,
                cwd=tmp,
            )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("ruff", result.stdout + result.stderr)

    def test_workspace_root_runs_tool_directly(self):
        wrapper = rlocation("mise/tools/ruff/workspace_root")
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [wrapper, "--version"],
                capture_output=True,
                text=True,
                check=False,
                cwd=tempfile.gettempdir(),
                env={
                    **os.environ,
                    "BUILD_WORKSPACE_DIRECTORY": tmp,
                },
            )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("ruff", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
