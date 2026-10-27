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
    # On Windows the wrappers are `.bat` files, which CreateProcess cannot
    # launch directly: resolve the `.bat` explicitly and run it via cmd.
    if os.name == "nt" and not path.endswith(".bat"):
        bat = r.Rlocation(path + ".bat")
        if bat is not None:
            return ["cmd.exe", "/c", bat]
    resolved = r.Rlocation(path)
    assert resolved is not None, f"missing runfile: {path}"
    return [resolved]


def run_ruff_check(wrapper, process_cwd, extra_env):
    # `x.py` exists only in the directory the tool is expected to run from, so
    # ruff reports its unused import only when the wrapper changed into it.
    env = dict(os.environ)
    env.pop("BUILD_WORKING_DIRECTORY", None)
    env.pop("BUILD_WORKSPACE_DIRECTORY", None)
    env.update(extra_env)
    return subprocess.run(
        rlocation(wrapper)
        + ["check", "--isolated", "--no-cache", "--select", "F401", "x.py"],
        capture_output=True,
        text=True,
        check=False,
        cwd=process_cwd,
        env=env,
    )


class WrapperTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.target = os.path.join(tmp.name, "target")
        self.elsewhere = os.path.join(tmp.name, "elsewhere")
        os.mkdir(self.target)
        os.mkdir(self.elsewhere)
        with open(os.path.join(self.target, "x.py"), "w") as f:
            f.write("import os\n")

    def assertRanInTarget(self, result):
        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("F401", result.stdout)

    def test_cwd_runs_tool_in_build_working_directory(self):
        result = run_ruff_check(
            "mise/tools/ruff/cwd",
            self.elsewhere,
            {"BUILD_WORKING_DIRECTORY": self.target},
        )
        self.assertRanInTarget(result)

    def test_cwd_without_build_working_directory_stays_in_cwd(self):
        result = run_ruff_check("mise/tools/ruff/cwd", self.target, {})
        self.assertRanInTarget(result)

    def test_workspace_root_runs_tool_in_build_workspace_directory(self):
        result = run_ruff_check(
            "mise/tools/ruff/workspace_root",
            self.elsewhere,
            {
                "BUILD_WORKSPACE_DIRECTORY": self.target,
                "BUILD_WORKING_DIRECTORY": self.elsewhere,
            },
        )
        self.assertRanInTarget(result)

    def test_workspace_root_without_build_workspace_directory_stays_in_cwd(self):
        result = run_ruff_check("mise/tools/ruff/workspace_root", self.target, {})
        self.assertRanInTarget(result)


if __name__ == "__main__":
    unittest.main()
