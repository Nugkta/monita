"""Install or update Monita without changing its separate review data.

Monita was called Task Island before 0.2.14. An installed `Task Island.app` with
Monita's bundle identifier is treated as the previous version: it is stopped,
kept in backups/, and replaced by `Monita.app`. A `Task Island.app` from anyone
else is left alone. Review history and settings live outside the app bundle and
are never touched here.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('--install-dir', type=Path, default=Path.home() / 'Applications')
parser.add_argument('--no-launch', action='store_true', help='Install without starting observers')
parser.add_argument('--expanded', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent
source = root / 'Monita.app'
install_dir = args.install_dir.expanduser().resolve()
target = install_dir / 'Monita.app'
legacy = install_dir / 'Task Island.app'
bundle_id = 'local.taskisland.status'


def info(path):
    with (path / 'Contents/Info.plist').open('rb') as handle:
        return plistlib.load(handle)


def legacy_install():
    """The Info.plist of a `Task Island.app` that is an earlier Monita, else None."""
    if legacy.is_symlink() or not legacy.is_dir():
        return None
    try:
        data = info(legacy)
    except (OSError, plistlib.InvalidFileException):
        return None
    return data if data.get('CFBundleIdentifier') == bundle_id else None


def processes(bundles):
    """Running app and observer processes started from any of `bundles`."""
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,command='], text=True)
    watched = []
    for path, data in bundles:
        app = str(path / 'Contents/MacOS' / data.get('CFBundleExecutable', 'Monita'))
        observer = str(path / 'Contents/Resources/node') + ' --no-warnings ' + str(path / 'Contents/Resources/bridge.mjs')
        watched.append((app, observer))
    result = []
    for line in rows.splitlines():
        pid, _ppid, command = line.strip().split(None, 2)
        for app, observer in watched:
            if command == app or command.startswith(app + ' '):
                result.append((int(pid), 'app'))
            elif command.startswith(observer + ' --parent-pid '):
                result.append((int(pid), 'observer'))
    return result


def stop(bundles):
    for kind_to_stop, wait in (('app', 5), ('observer', 2)):
        for pid, kind in processes(bundles):
            if kind == kind_to_stop:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + wait
        while processes(bundles) and time.monotonic() < deadline:
            time.sleep(0.1)
    if processes(bundles):
        raise RuntimeError('The previous Monita did not stop; existing installation preserved')


new = info(source)
expected = plistlib.loads((root / 'Info.plist').read_bytes())['CFBundleShortVersionString']
if new.get('CFBundleIdentifier') != bundle_id or new.get('CFBundleShortVersionString') != expected:
    raise RuntimeError('Built app does not match Info.plist; run build.sh first')
if target.is_symlink():
    raise RuntimeError('Refusing to replace an installation symlink')
old = info(target) if target.exists() else None
if old and old.get('CFBundleIdentifier') != bundle_id:
    raise RuntimeError('Refusing to replace an unrelated application')
renamed = legacy_install()
previous = [(path, data) for path, data in ((target, old), (legacy, renamed)) if data]

subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(source)], check=True)
target.parent.mkdir(parents=True, exist_ok=True)
stage = target.with_name('Monita.update-' + uuid.uuid4().hex + '.app')
subprocess.run(['/usr/bin/ditto', str(source), str(stage)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
stop(previous)

moved = []
if previous:
    backups = root / 'backups'
    backups.mkdir(exist_ok=True)
try:
    for path, data in previous:
        backup = backups / (path.stem + '-' + data.get('CFBundleShortVersionString', 'unknown') + '-' + uuid.uuid4().hex + '.app')
        os.rename(path, backup)
        moved.append((path, backup))
    os.rename(stage, target)
except BaseException:
    for path, backup in reversed(moved):
        os.rename(backup, path)
    raise

if not args.no_launch:
    launch = ['/usr/bin/open', str(target)]
    if args.expanded:
        launch += ['--args', '--expanded']
    subprocess.run(launch, check=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        running = processes([(target, new)])
        if sum(kind == 'app' for _, kind in running) == 1 and sum(kind == 'observer' for _, kind in running) == 1:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError('Installed app launch could not be verified; installed bundle preserved')
report = {'installed': True, 'version': expected, 'applicationPath': str(target),
          'previousVersion': (old or renamed or {}).get('CFBundleShortVersionString'),
          'replacedTaskIslandApp': renamed is not None,
          'signatureVerified': True, 'launchRequested': not args.no_launch,
          'backupCreated': bool(moved), 'stateDirectoryTouchedByInstaller': False,
          'launchAtLoginConfigured': False}
(root / 'install-result.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
