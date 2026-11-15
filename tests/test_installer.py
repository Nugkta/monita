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
        target = self.destination / 'Monita.app'
        info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'local.taskisland.status')
        second = self.install()
        self.assertEqual(second.returncode, 0, second.stderr)
        updated = json.loads(second.stdout)
        self.assertEqual(updated['previousVersion'], initial['version'])
        self.assertTrue(updated['backupCreated'])
        self.assertFalse(updated['launchRequested'])
        self.assertFalse(updated['stateDirectoryTouchedByInstaller'])
        self.assertFalse(updated['replacedTaskIslandApp'])

    def fake_bundle(self, name, bundle_id, version='0.2.13'):
        contents = self.destination / name / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        path = contents / 'Info.plist'
        path.write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id, 'CFBundleShortVersionString': version,
                                         'CFBundleExecutable': 'TaskIsland'}))
        return path

    def test_installed_task_island_is_replaced_by_monita(self):
        self.fake_bundle('Task Island.app', 'local.taskisland.status')
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report['replacedTaskIslandApp'])
        self.assertEqual(report['previousVersion'], '0.2.13')
        self.assertTrue(report['backupCreated'])
        self.assertFalse((self.destination / 'Task Island.app').exists(), 'The old name must not linger beside Monita')
        self.assertTrue((self.destination / 'Monita.app/Contents/Info.plist').exists())
        created = set(self.backups.glob('*.app')) - self.previous_backups
        self.assertTrue(any(path.name.startswith('Task Island-0.2.13-') for path in created), created)

    def test_someone_elses_task_island_is_left_alone(self):
        path = self.fake_bundle('Task Island.app', 'org.example.unrelated', '1.0')
        original = path.read_bytes()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['replacedTaskIslandApp'])
        self.assertEqual(path.read_bytes(), original)
        self.assertTrue((self.destination / 'Monita.app').exists())

    def test_unrelated_application_is_preserved(self):
        contents = self.destination / 'Monita.app/Contents'
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
