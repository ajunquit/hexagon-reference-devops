"""Tests of the cloud split inventory (scripts/cloud_classification.py)."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import cloud_classification as cc  # noqa: E402


def is_template() -> bool:
    """The inventory describes the template; product instances migrate through the factory."""
    return json.loads((ROOT / '.config' / 'product.json').read_text(encoding='utf-8'))['product'] == 'hexagon-template'


class CloudClassificationTests(unittest.TestCase):
    @unittest.skipUnless(is_template(), 'The cloud inventory applies to the template only.')
    def test_the_repository_is_completely_and_consistently_classified(self):
        self.assertEqual([], cc.check(ROOT))

    def test_the_first_matching_rule_wins_and_unused_rules_are_reported(self):
        rules = [{'pattern': 'scripts/Aws*', 'scope': 'aws'}, {'pattern': 'scripts/*', 'scope': 'common'},
                 {'pattern': 'docs/*', 'scope': 'common'}]
        classified, unmatched, unused = cc.classify(['scripts/AwsStore.psm1', 'scripts/Tool.ps1', 'README.md'], rules)
        self.assertEqual(['aws', 'common'], [item.scope for item in classified])
        self.assertEqual(['README.md'], unmatched)
        self.assertEqual(['docs/*'], unused)

    def test_a_common_file_cannot_name_a_cloud_and_a_cloud_cannot_name_the_other(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {'common.ps1': ('common', 'Write-Output "upload to S3"'),
                     'provider.ps1': ('common', "if ($provider -eq 'azure-service-bus') { }"),
                     'aws.ps1': ('aws', '# Same as the Azure store'),
                     'azure.ps1': ('azure', '# Uses Key Vault'),
                     'adr.md': ('history', 'AWS and Azure')}
            for name, (_, text) in files.items():
                (root / name).write_text(text, encoding='utf-8')
            classified = [cc.Classified(name, scope, name) for name, (scope, _) in files.items()]
            found = cc.violations(root, classified)
        self.assertEqual(2, len(found))
        self.assertTrue(found[0].startswith('common.ps1 (common)'))
        self.assertTrue(found[1].startswith('aws.ps1 (aws)'))

    def test_a_cloud_cannot_import_the_other_and_common_cannot_import_a_cloud(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            files = {'scripts/Shared.psm1': ('common', "Import-Module 'AwsStore'"),
                     'scripts/AwsStore.psm1': ('aws', "Import-Module 'AzureStore'; Import-Module 'Shared'"),
                     'scripts/AzureStore.psm1': ('azure', "Import-Module 'Helpers'"),
                     'scripts/Helpers.psm1': ('mixed', '')}
            for name, (_, text) in files.items():
                (root / name).write_text(text, encoding='utf-8')
            classified = [cc.Classified(name, scope, name) for name, (scope, _) in files.items()]
            found = cc.imports(root, classified)
        self.assertEqual(['scripts/Shared.psm1 (common) imports scripts/AwsStore.psm1 (aws)',
                          'scripts/AwsStore.psm1 (aws) imports scripts/AzureStore.psm1 (azure)'], found)

    def test_a_mixed_rule_must_say_how_it_is_split(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'scripts' / 'cloud-classification.json').write_text(
                '{"rules": [{"pattern": "*", "scope": "mixed"}]}', encoding='utf-8')
            with self.assertRaises(ValueError):
                cc.load(root)


if __name__ == '__main__':
    unittest.main()
