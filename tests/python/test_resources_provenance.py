"""Ensure the vendored helper stays identical to its reviewed source pin."""
import hashlib
import json
import re
import unittest
from pathlib import Path


class ResourceProvenanceTests(unittest.TestCase):
    def test_vendored_resource_guard_matches_immutable_source(self):
        root = Path(__file__).resolve().parents[2]
        manifest = json.loads((root / 'scripts/workspace-resources-source.json').read_text())
        code = (root / manifest['path']).read_bytes().replace(b'\r\n', b'\n')
        self.assertEqual(manifest['repository'], 'ajunquit/hexagon-ai-tools')
        self.assertRegex(manifest['commit'], re.compile(r'^[0-9a-f]{40}$'))
        self.assertEqual(hashlib.sha256(code).hexdigest(), manifest['sha256_lf'])


if __name__ == '__main__':
    unittest.main()
