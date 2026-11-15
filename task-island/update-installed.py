"""Install or update Task Island without changing its separate review data."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--install-dir', type=Path, default=Path.home() / 'Applications')
parser.add_argument('--no-launch', action='store_true', help='Install without starting observers')
parser.add_argument('--expanded', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent
source = root / 'Task Island.app'
target = args.install_dir.expanduser().resolve() / 'Task Island.app'
bundle_id = 'local.taskisland.status'

def info(path):
    with (path / 'Contents/Info.plist').open('rb') as handle:
        return plistlib.load(handle)

def processes():
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,command='], text=True)
    app = str(target / 'Contents/MacOS/TaskIsland')
    observer = str(target / 'Contents/Resources/node') + ' --no-warnings ' + str(target / 'Contents/Resources/bridge.mjs')
    result = []
    for line in rows.splitlines():
        pid, _ppid, command = line.strip().split(None, 2)
        if command == app or command.startswith(app + ' '):
            result.append((int(pid), 'app'))
        elif command.startswith(observer + ' --parent-pid '):
            result.append((int(pid), 'observer'))
    return result

new = info(source)
expected = plistlib.loads((root / 'Info.plist').read_bytes())['CFBundleShortVersionString']
if new.get('CFBundleIdentifier') != bundle_id or new.get('CFBundleShortVersionString') != expected:
    raise RuntimeError('Built app does not match Info.plist; run build.sh first')
if target.is_symlink():
    raise RuntimeError('Refusing to replace an installation symlink')
old = info(target) if target.exists() else None
if old and old.get('CFBundleIdentifier') != bundle_id:
    raise RuntimeError('Refusing to replace an unrelated application')
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(source)], check=True)
target.parent.mkdir(parents=True, exist_ok=True)
stage = target.with_name('Task Island.update-' + uuid.uuid4().hex + '.app')
subprocess.run(['/usr/bin/ditto', str(source), str(stage)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
for pid, kind in processes():
    if kind == 'app':
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
deadline = time.monotonic() + 5
while processes() and time.monotonic() < deadline:
    time.sleep(0.1)
for pid, kind in processes():
    if kind == 'observer':
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
deadline = time.monotonic() + 2
while processes() and time.monotonic() < deadline:
    time.sleep(0.1)
if processes():
    raise RuntimeError('The previous Task Island did not stop; existing installation preserved')
backup = None
if old:
    backups = root / 'backups'
    backups.mkdir(exist_ok=True)
    backup = backups / ('Task Island-' + old['CFBundleShortVersionString'] + '-' + uuid.uuid4().hex + '.app')
    os.rename(target, backup)
try:
    os.rename(stage, target)
except BaseException:
    if backup:
        os.rename(backup, target)
    raise
if not args.no_launch:
    launch = ['/usr/bin/open', str(target)]
    if args.expanded:
        launch += ['--args', '--expanded']
    subprocess.run(launch, check=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        running = processes()
        if sum(kind == 'app' for _, kind in running) == 1 and sum(kind == 'observer' for _, kind in running) == 1:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError('Installed app launch could not be verified; installed bundle preserved')
report = {'installed': True, 'version': expected, 'applicationPath': str(target),
          'previousVersion': old['CFBundleShortVersionString'] if old else None,
          'signatureVerified': True, 'launchRequested': not args.no_launch,
          'backupCreated': backup is not None, 'stateDirectoryTouchedByInstaller': False,
          'launchAtLoginConfigured': False}
(root / 'install-result.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
