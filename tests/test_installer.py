"""Packaging checks against a built app; never launch it or use the real install."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'task-island'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='task-island-installer-test-')
        self.destination = Path(self.temp.name) / 'new-applications'
        self.backups = APP / 'backups'
        self.previous_backups = set(self.backups.glob('*.app'))

    def tearDown(self):
        # Delete only bundles created by this test; preserve existing backups.
        for path in set(self.backups.glob('*.app')) - self.previous_backups:
            shutil.rmtree(path)
        self.temp.cleanup()

    def install(self):
        return subprocess.run([
            sys.executable, str(APP / 'update-installed.py'),
            '--install-dir', str(self.destination), '--no-launch',
        ], capture_output=True, text=True, timeout=60)

    def test_first_install_and_update_without_launch(self):
        self.assertFalse(self.destination.exists())
        first = self.install()
        self.assertEqual(first.returncode, 0, first.stderr)
        initial = json.loads(first.stdout)
        self.assertIsNone(initial['previousVersion'])
        self.assertFalse(initial['launchRequested'])
        self.assertFalse(initial['backupCreated'])
        target = self.destination / 'Task Island.app'
        info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'local.taskisland.status')
        second = self.install()
        self.assertEqual(second.returncode, 0, second.stderr)
        updated = json.loads(second.stdout)
        self.assertEqual(updated['previousVersion'], initial['version'])
        self.assertTrue(updated['backupCreated'])
        self.assertFalse(updated['launchRequested'])
        self.assertFalse(updated['stateDirectoryTouchedByInstaller'])

    def test_unrelated_application_is_preserved(self):
        contents = self.destination / 'Task Island.app/Contents'
        contents.mkdir(parents=True)
        original = plistlib.dumps({'CFBundleIdentifier': 'org.example.unrelated',
                                   'CFBundleShortVersionString': '1.0'})
        path = contents / 'Info.plist'
        path.write_bytes(original)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unrelated application', result.stderr)
        self.assertEqual(path.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
