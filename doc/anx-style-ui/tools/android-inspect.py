#!/usr/bin/env python3
"""Capture a fixed set of read-only diagnostics from the owned Anx test AVD."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from android_common import AVD_NAME, SDK, SERIAL, WORK, owned_process


def simple_name(value):
    if not value or any(char not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for char in value):
        raise argparse.ArgumentTypeError('use a simple directory name containing letters, digits, hyphens or underscores')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', type=simple_name, required=True)
    parser.add_argument('--label', type=simple_name, required=True)
    args = parser.parse_args()
    evidence_root = WORK / 'evidence/W35'
    out = evidence_root / args.run_id / 'diagnostics' / args.label
    if not out.resolve().is_relative_to(evidence_root.resolve()):
        parser.error('diagnostics must remain inside the W35 evidence directory')
    out.mkdir(parents=True, exist_ok=False)
    source = out / 'source'
    source.mkdir()
    hashes = {}
    for name in ('android-inspect.py', 'android_common.py'):
        original = Path(__file__).with_name(name)
        shutil.copy2(original, source / name)
        hashes[name] = hashlib.sha256(original.read_bytes()).hexdigest()
    environment = os.environ.copy()
    environment['ADB_VENDOR_KEYS'] = str(WORK / 'android-adb')
    report = {'serial': SERIAL, 'avd': AVD_NAME, 'source_sha256': hashes,
              'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'read_only': True, 'commands': [], 'complete': False}

    def capture(filename, arguments):
        command = [str(SDK / 'platform-tools/adb'), '-s', SERIAL, *arguments]
        record = {'command': command, 'output': filename, 'exit_code': None}
        started = time.monotonic()
        stdout, stderr = b'', b''
        try:
            completed = subprocess.run(command, env=environment, timeout=30,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            stdout, stderr = completed.stdout, completed.stderr
            record['exit_code'] = completed.returncode
            if completed.returncode:
                record['error'] = {'kind': 'command_failed', 'returncode': completed.returncode}
        except subprocess.TimeoutExpired as error:
            stdout, stderr = error.stdout or b'', error.stderr or b''
            record['error'] = {'kind': 'timeout', 'seconds': error.timeout}
            record['partial'] = True
        except OSError as error:
            record['error'] = {'kind': 'os_error', 'errno': error.errno, 'message': str(error)}
        record['elapsed_seconds'] = round(time.monotonic() - started, 3)
        (out / filename).write_bytes(stdout)
        stderr_name = filename + '.stderr.txt'
        (out / stderr_name).write_bytes(stderr)
        record.update(bytes=len(stdout), stderr_bytes=len(stderr), stderr=stderr_name)
        report['commands'].append(record)
        return record, stdout

    try:
        launch = owned_process()
        report['launch'] = launch
        identity, output = capture('avd-name.txt', ['emu', 'avd', 'name'])
        names = output.decode(errors='replace').splitlines()
        if identity.get('error') or not names or names[0].strip() != AVD_NAME:
            raise RuntimeError('ADB serial did not confirm the owned dedicated AVD; no diagnostic commands sent')
        # No caller-controlled commands, serials, shell programs or device paths.
        for filename, arguments in (
            ('logcat.txt', ['logcat', '-d', '-v', 'threadtime']),
            ('activity-top.txt', ['shell', 'dumpsys', 'activity', 'top']),
            ('window-windows.txt', ['shell', 'dumpsys', 'window', 'windows']),
            ('window-policy.txt', ['shell', 'dumpsys', 'window', 'policy']),
            ('data-files.txt', ['shell', 'ls', '-la', '/sdcard/koreader', '/sdcard/koreader/patches']),
            ('screen.png', ['exec-out', 'screencap', '-p']),
        ):
            owned_process(launch)
            capture(filename, arguments)
        report['complete'] = all(not item.get('error') for item in report['commands'])
    except (OSError, RuntimeError, ValueError) as error:
        report['error'] = str(error)
    finally:
        report['finished_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (out / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'complete': report['complete'], 'result': str(out / 'result.json'),
                      'command_errors': sum(bool(item.get('error')) for item in report['commands']),
                      'identity_error': report.get('error')}))
    return 0 if report['complete'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
