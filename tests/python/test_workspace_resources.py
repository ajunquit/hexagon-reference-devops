"""Real hardlink/configuration/locking tests and simulated Terraform subprocesses."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('resources', Path(__file__).resolve().parents[2] / 'scripts/workspace_resources.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WorkspaceResourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir()
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        self.cli = self.root / 'terraform.rc'
        self.tfroot = self.workspace / '.worktrees/project/terraform'
        self.tfroot.mkdir(parents=True)
        self.providers = self.tfroot / '.terraform/providers'
        self.relative = Path('registry.terraform.io/hashicorp/random/3.7.2/windows_amd64/terraform-provider-random_v3.7.2.exe')
        self.settings = {'root': self.workspace, 'cache': self.cache, 'workspace_gib': 50, 'cache_gib': 15}

    def pair(self, local=b'provider', shared=b'provider'):
        cache_file, local_file = self.cache / self.relative, self.providers / self.relative
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        local_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_bytes(shared)
        local_file.write_bytes(local)
        return local_file, cache_file

    def test_configure_preserves_existing_settings_and_is_idempotent(self):
        self.cli.write_text('disable_checkpoint = true\n')
        MODULE.configure(self.workspace, self.cache, cli_config=self.cli)
        before = self.cli.read_bytes()
        MODULE.configure(self.workspace, self.cache, cli_config=self.cli)
        self.assertEqual(before, self.cli.read_bytes())
        self.assertIn('disable_checkpoint = true', before.decode())
        self.assertEqual(before.decode().count('plugin_cache_dir'), 1)
        self.assertEqual((self.workspace / 'CLAUDE.md').read_text().count('@AGENTS.md'), 1)
        profile = json.loads((self.workspace / '.tools/workspace-resources.json').read_text())
        self.assertEqual(Path(profile['cache_dir']), self.cache)

    def test_conflicting_existing_cli_cache_is_not_overwritten(self):
        self.cli.write_text('plugin_cache_dir = "existing"\n')
        before = self.cli.read_bytes()
        with self.assertRaises(RuntimeError):
            MODULE.configure(self.workspace, self.cache, cli_config=self.cli)
        self.assertEqual(before, self.cli.read_bytes())
        self.assertFalse((self.workspace / '.tools/workspace-resources.json').exists())

    def test_budget_blocks_workspace_and_cache_overflow(self):
        file = self.tfroot / 'large'
        file.write_bytes(b'x' * 1024)
        settings = dict(self.settings, workspace_gib=512 / MODULE.GIB)
        with self.assertRaises(RuntimeError):
            MODULE.check(settings)
        (self.cache / 'large').write_bytes(b'x' * 1024)
        settings = dict(self.settings, cache_gib=512 / MODULE.GIB)
        with self.assertRaises(RuntimeError):
            MODULE.check(settings, cache_only=True)

    def test_deduplication_uses_real_shared_storage_and_repeat_is_noop(self):
        local, shared = self.pair()
        self.assertFalse(os.path.samefile(local, shared))
        self.assertEqual(MODULE.deduplicate(self.providers, self.cache), 1)
        self.assertTrue(os.path.samefile(local, shared))
        self.assertEqual(MODULE.deduplicate(self.providers, self.cache), 0)
        another = local.parent / 'another-link'
        os.link(shared, another)
        self.assertEqual(MODULE.disk_bytes(self.providers), len(b'provider'))

    def test_changed_content_is_retained(self):
        local, _ = self.pair(local=b'custom input')
        with self.assertRaises(RuntimeError):
            MODULE.deduplicate(self.providers, self.cache)
        self.assertEqual(local.read_bytes(), b'custom input')

    def test_no_hardlink_support_stops_without_discarding_local_file(self):
        local, _ = self.pair()
        with patch.object(MODULE.os, 'link', side_effect=OSError('unsupported')):
            with self.assertRaises(OSError):
                MODULE.deduplicate(self.providers, self.cache)
        self.assertEqual(local.read_bytes(), b'provider')
        self.assertFalse(list(local.parent.glob('.hexagon-link-*')))

    def test_install_lock_serializes_callers_and_releases_on_error(self):
        with MODULE.install_lock(self.cache):
            with self.assertRaises(RuntimeError):
                with MODULE.install_lock(self.cache, timeout=0):
                    pass
        with MODULE.install_lock(self.cache, timeout=0):
            pass

    def test_init_uses_cache_and_shares_provider_after_success(self):
        def run(command, env):
            self.assertEqual(command[2], 'init')
            self.assertEqual(env['TF_PLUGIN_CACHE_DIR'], str(self.cache))
            self.pair()
            return subprocess.CompletedProcess(command, 0)
        with patch.object(MODULE.subprocess, 'run', side_effect=run):
            self.assertEqual(MODULE.initialize(self.tfroot, self.settings, ['-backend=false'], executable='terraform-test'), 0)
        self.assertTrue(os.path.samefile(self.providers / self.relative, self.cache / self.relative))

    def test_budget_stops_before_terraform_and_exit_code_is_preserved(self):
        (self.tfroot / 'large').write_bytes(b'xx')
        with patch.object(MODULE.subprocess, 'run') as run:
            with self.assertRaises(RuntimeError):
                MODULE.initialize(self.tfroot, dict(self.settings, workspace_gib=1 / MODULE.GIB), executable='unused')
            run.assert_not_called()
        with patch.object(MODULE.subprocess, 'run', return_value=subprocess.CompletedProcess([], 17)):
            self.assertEqual(MODULE.initialize(self.tfroot, self.settings, executable='unused'), 17)

    def test_invalid_budget_and_disposable_cache_location_are_rejected(self):
        with self.assertRaises(RuntimeError):
            MODULE.configure(self.workspace, self.tfroot / 'cache', cli_config=self.cli)
        for value in (0, -1, float('nan'), float('inf')):
            with self.assertRaises(RuntimeError):
                MODULE.configure(self.workspace, self.cache, workspace_gib=value, cli_config=self.cli)

    def test_outside_terraform_root_is_never_run(self):
        with patch.object(MODULE.subprocess, 'run') as run:
            with self.assertRaises(RuntimeError):
                MODULE.initialize(self.root, self.settings, executable='unused')
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
