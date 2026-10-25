"""Smoke test for tools from every supported mise backend.

Each entry maps the runfiles path of a `@mise//tools/...` target to a
substring expected in its `--version` output. This exercises the
backend-specific lockfile shapes (plain `aqua:`/`core:` registry entries,
explicit `backend:` prefixes, `http:` URLs without checksums, `blake3:`
checksums that must be ignored as unverifiable, ...).
"""

import subprocess
import unittest

from runfiles import Runfiles

r = Runfiles.Create()

# (runfiles path, substring expected in `tool --version` output, or None
# when the tool prints a bare version without its own name)
TOOLS = [
    ("mise/tools/bun/bun", None),
    ("mise/tools/ruff/ruff", "ruff"),
    ("mise/tools/aqua_mikefarah_yq/aqua_mikefarah_yq", "yq"),
    ("mise/tools/github_mikefarah_yq/github_mikefarah_yq", "yq"),
    ("mise/tools/http_yq/http_yq", "yq"),
    ("mise/tools/http_yq_blake3/http_yq_blake3", "yq"),
    ("mise/tools/gitlab_gitlab-org_release-cli/gitlab_gitlab-org_release-cli", "release-cli"),
    ("mise/tools/forgejo_gitea_tea/forgejo_gitea_tea", None),
    ("mise/tools/packslip_github.com_jdx_hk/packslip_github.com_jdx_hk", "hk"),
]


class BackendsTest(unittest.TestCase):
    def test_tools_report_version(self):
        for path, expected in TOOLS:
            with self.subTest(tool=path):
                binary = r.Rlocation(path)
                self.assertIsNotNone(binary, msg=f"missing runfile: {path}")
                result = subprocess.run(
                    [binary, "--version"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, msg=output)
                if expected is None:
                    self.assertTrue(output.strip(), msg="empty --version output")
                else:
                    self.assertIn(expected, output)


if __name__ == "__main__":
    unittest.main()
