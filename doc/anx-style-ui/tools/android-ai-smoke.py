#!/usr/bin/env python3
"""Verify AI upgrade persistence and runtime only on the owned Android emulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from android_common import apk_badging, check_apk_identity, owned_process

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--apk', type=Path, required=True)
parser.add_argument('--book', type=Path, required=True)
parser.add_argument('--run-id', required=True)
parser.add_argument('--previous', type=Path, required=True)
parser.add_argument('--resume-ui', action='store_true', help='Retain existing seeded private data; rerun UI and restart phases only')
parser.add_argument('--reopen-only', action='store_true', help='Verify restart after a separately completed UI phase')
parser.add_argument('--collect-ui-run', help='Collect the real device result from an interrupted host run before restarting')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
work = Path('/data/koreader-anx-work')
if not args.run_id or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.run_id):
    parser.error('simple run-id required')
args.apk = args.apk.resolve(); args.book = args.book.resolve()
if not args.apk.is_relative_to(work) or not args.book.is_relative_to(work):
    parser.error('use isolated build and self-authored fixture paths')
if not args.apk.is_file() or not args.book.is_file():
    parser.error('APK and fixture must be existing files')
out = work / 'evidence/W46-ai-tools' / args.run_id
out.mkdir(parents=True, exist_ok=False)
sdk = repo / 'base/toolchain/android-sdk-linux'
adb = sdk / 'platform-tools/adb'
serial = 'emulator-5584'
package = 'org.koreader.launcher'
component = package + '/.MainActivity'
remote = '/sdcard/anx-lab/' + args.run_id
book = remote + '/Android-S01.epub'
environment = os.environ.copy()
environment['ADB_VENDOR_KEYS'] = str(work / 'android-adb')
commands = []

def run(*parts, timeout=40, check=True, binary=False, raw=False):
    owned_process()
    invocation = [str(adb), '-s', serial, *map(str, parts)]
    try:
        result = subprocess.run(invocation, env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=not binary, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as error:
        commands.append({'command': invocation, 'exit_code': None, 'error': str(error)})
        raise
    commands.append({'command': invocation, 'exit_code': result.returncode})
    if check: result.check_returncode()
    return result if raw else result.stdout

def target_identity():
    launch = owned_process()
    names = run('emu', 'avd', 'name').splitlines()
    if not names or names[0].strip() != 'anxui-api30' or run('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('target must be the owned, dedicated anxui-api30 emulator')
    return launch


def resumed_components(dump):
    """Read Android 11 `dumpsys activity top` activity blocks, not task names."""
    current, resumed = None, []
    for line in dump.splitlines():
        match = re.match(r'^\s*ACTIVITY\s+([^\s]+/[^\s]+)\s', line)
        if match:
            current = match.group(1)
        elif current and re.match(r'^\s*mResumed=true(?:\s|$)', line):
            resumed.append(current)
    return resumed


def wait_foreground(directory, label, ours):
    deadline, observations = time.monotonic() + 45, []
    while time.monotonic() < deadline:
        index = len(observations) + 1
        output, stderr = '', ''
        observation = {'attempt': index}
        try:
            response = run('shell', 'dumpsys', 'activity', 'top', check=False, raw=True,
                           timeout=min(15, max(.1, deadline - time.monotonic())))
            output, stderr = response.stdout, response.stderr
            observation['exit_code'] = response.returncode
            components = resumed_components(output) if response.returncode == 0 else []
            observation['resumed_components'] = components
            observation['matched'] = (len(components) == 1
                                      and (components[0].split('/')[0] == package) == ours)
        except subprocess.TimeoutExpired as error:
            output, stderr = error.stdout or '', error.stderr or ''
            if isinstance(output, bytes): output = output.decode(errors='replace')
            if isinstance(stderr, bytes): stderr = stderr.decode(errors='replace')
            observation.update(error='dumpsys activity top timed out', matched=False)
        except OSError as error:
            observation.update(error=str(error), matched=False)
        filename = label + '-' + str(index) + '.txt'
        (directory / filename).write_text(output)
        (directory / (filename + '.stderr.txt')).write_text(stderr)
        observation['dump'] = filename
        observations.append(observation)
        (directory / (label + '.json')).write_text(json.dumps(observations, indent=2) + '\n')
        if observation['matched']:
            return observation
        time.sleep(min(1, max(0, deadline - time.monotonic())))
    expected = 'KOReader resumed' if ours else 'a different activity resumed'
    raise TimeoutError('Android background/resume verification: ' + label + ' did not show ' + expected + ' within 45 seconds')


launch = target_identity()
if run('shell', 'getprop', 'sys.boot_completed').strip() != '1':
    parser.error('wait for emulator boot completion')
args.previous = args.previous.resolve()
for apk in (args.previous, args.apk):
    if not apk.is_relative_to(work): parser.error('use isolated APK paths')
    record = json.loads((apk.parent / 'package.json').read_text())
    if not record['passed'] or record['sha256'] != hashlib.sha256(apk.read_bytes()).hexdigest():
        parser.error('APK identity mismatch')
    check_apk_identity(record['manifest'], 'x86_64')
record = json.loads((args.apk.parent / 'package.json').read_text())
plugin_files = {str(p.relative_to(repo / 'plugins/anxui.koplugin')): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (repo / 'plugins/anxui.koplugin').rglob('*') if p.is_file()}
if plugin_files != record['anxui_source_files']: parser.error('source changed since APK build')
import importlib.util
spec = importlib.util.spec_from_file_location('ai_fixture', Path(__file__).with_name('ai-fixture-server.py'))
fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
service = fixture.AIService()
port = service.server.server_port
result = {'passed': False, 'apk': str(args.apk), 'sha256': record['sha256'], 'previous': str(args.previous),
          'backend': 'owned Android 11 / API30 x86_64 emulator; dummy credential and local SSE service',
          'phases': [], 'cleared_app_data': False, 'resumed_ui': args.resume_ui, 'reopen_only': args.reopen_only}
source = out / 'source'; source.mkdir()
for name in ('android-ai-smoke.py', 'android-ai-smoke.lua', 'android_common.py', 'ai-fixture-server.py'):
    shutil.copy2(Path(__file__).with_name(name), source / name)
shutil.copy2(args.apk.parent / 'package.json', out / 'package.json')
prepared = False
try:
    if args.collect_ui_run:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', args.collect_ui_run): raise ValueError('invalid previous run name')
        prior_record = json.loads((out.parent / args.collect_ui_run / 'package.json').read_text())
        if prior_record['sha256'] != record['sha256']: raise ValueError('previous UI APK differs')
        collected = json.loads(run('shell', 'cat', '/sdcard/anx-lab/' + args.collect_ui_run + '/ui/result.json'))
        (out / 'collected-ui.json').write_text(json.dumps(collected, ensure_ascii=False, indent=2) + '\n')
        if not collected['passed']: raise RuntimeError('collected device UI assertions did not pass')
        result['collected_ui'] = {'run': args.collect_ui_run, 'result': collected}
    run('shell', 'am', 'force-stop', package)
    run('shell', 'mkdir', '-p', '/sdcard/anx-lab')
    run('shell', 'mkdir', remote)
    prior = run('shell', 'test', '-e', '/sdcard/koreader', check=False, raw=True)
    if prior.returncode == 0: run('shell', 'mv', '/sdcard/koreader', remote + '/previous-koreader')
    elif prior.returncode != 1: prior.check_returncode()
    run('shell', 'mkdir', '-p', '/sdcard/koreader/patches')
    run('push', args.book, book)
    run('push', Path(__file__).with_name('android-ai-smoke.lua'), '/sdcard/koreader/patches/2-anx-ai-test.lua')
    prepared = True
    settings = out / 'settings.reader.lua'
    settings.write_text('return {color_rendering=true,language="zh_CN",keyboard_layout="en",virtual_keyboard_enabled=true,'
                        'quickstart_shown_version=9999999999,extra_plugin_paths={},plugins_disabled={},start_with="filemanager",'
                        'home_dir=' + json.dumps(remote) + ',lastdir=' + json.dumps(remote) + ',anxui={schema=1,mode="color",startup=true}}\n')
    run('push', settings, '/sdcard/koreader/settings.reader.lua')
    run('reverse', 'tcp:' + str(port), 'tcp:' + str(port))
    phases = ('reopen',) if args.reopen_only else (('ui', 'reopen') if args.resume_ui else ('seed', 'ui', 'reopen'))
    for phase in phases:
        if phase != 'reopen':
            # No pm clear: the new APK must retain the legacy private AI data.
            run('install', '-r', args.previous if phase == 'seed' else args.apk, timeout=180)
            run('shell', 'appops', 'set', '--uid', package, 'MANAGE_EXTERNAL_STORAGE', 'allow')
        phase_dir = out / phase; phase_dir.mkdir()
        phase_remote = remote + '/' + phase
        run('shell', 'mkdir', '-p', phase_remote)
        control = out / 'control.json'
        control.write_text(json.dumps({'phase': phase, 'remote': phase_remote, 'book': book, 'url': service.url,
                                       'run_id': args.run_id}))
        run('push', control, '/sdcard/koreader/anx-android-control.json')
        run('logcat', '-c')
        run('shell', 'am', 'start', '-n', component)
        deadline, handled, outcome = time.monotonic() + 300, set(), None
        while time.monotonic() < deadline:
            text = run('shell', 'cat', phase_remote + '/result.json', check=False).strip()
            if text:
                try: outcome = json.loads(text)
                except json.JSONDecodeError: pass
                if outcome: break
            text = run('shell', 'cat', phase_remote + '/request.json', check=False).strip()
            try: request = json.loads(text)
            except json.JSONDecodeError: request = None
            if request and request['id'] not in handled:
                handled.add(request['id'])
                for action in request['actions']:
                    if action['kind'] == 'screenshot':
                        (phase_dir / (action['name'] + '.png')).write_bytes(run('exec-out', 'screencap', '-p', binary=True))
                    elif action['kind'] == 'tap': run('shell', 'input', 'tap', action['x'], action['y'])
                    elif action['kind'] == 'key': run('shell', 'input', 'keyevent', action['code'])
                    elif action['kind'] == 'background_resume':
                        directory = phase_dir / ('background-' + str(request['id'])); directory.mkdir()
                        wait_foreground(directory, 'before', True)
                        run('shell', 'input', 'keyevent', '3')
                        wait_foreground(directory, 'background', False)
                        run('shell', 'am', 'start', '-n', component)
                        wait_foreground(directory, 'resumed', True)
                    else: raise ValueError('unsupported input')
                response = out / 'response.json'; response.write_text(json.dumps({'id': request['id'], 'ok': True}))
                run('push', response, phase_remote + '/response.json.tmp')
                run('shell', 'mv', phase_remote + '/response.json.tmp', phase_remote + '/response.json')
            time.sleep(.3)
        (phase_dir / 'logcat.log').write_text(run('logcat', '-d', '-v', 'threadtime'))
        run('shell', 'am', 'force-stop', package)
        if not outcome: raise TimeoutError('Android AI phase timed out: ' + phase)
        (phase_dir / 'result.json').write_text(json.dumps(outcome, ensure_ascii=False, indent=2))
        result['phases'].append(outcome)
        if not outcome['passed']: raise RuntimeError(outcome.get('error', phase + ' failed'))
    result['passed'] = True
except Exception as error:
    result['error'] = str(error)
    (out / 'failure-logcat.log').write_text(run('logcat', '-d', '-v', 'threadtime'))
    (out / 'failure.png').write_bytes(run('exec-out', 'screencap', '-p', binary=True))
finally:
    if prepared:
        run('shell', 'am', 'force-stop', package)
        run('shell', 'mv', '/sdcard/koreader/patches/2-anx-ai-test.lua', '/sdcard/koreader/patches/2-anx-ai-test.lua.disabled', check=False)
    run('reverse', '--remove', 'tcp:' + str(port), check=False)
    service.close()
    result['fixture_requests'] = len(service.requests)
    result['commands'] = commands
    (out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'passed': result['passed'], 'result': str(out / 'result.json')}))
raise SystemExit(0 if result['passed'] else 1)
