#!/usr/bin/env python3
"""Validate a signed APK only on the isolated anxui-api30 emulator, with real adb input."""
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
out = work / 'evidence/W35' / args.run_id
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
    parser.error('wait for the emulator boot to finish')
badging = subprocess.check_output([str(sdk / 'build-tools/34.0.0/aapt'), 'dump', 'badging', str(args.apk)], text=True)
(out / 'manifest.log').write_text(badging)
identity = apk_badging(badging)
check_apk_identity(identity, 'x86_64')
package_record = json.loads((args.apk.parent / 'package.json').read_text())
apk_sha256 = hashlib.sha256(args.apk.read_bytes()).hexdigest()
if (not package_record.get('passed') or package_record.get('apk') != str(args.apk)
        or package_record.get('sha256') != apk_sha256 or package_record.get('abi') != 'x86_64'):
    parser.error('APK must have a passing identity record from android-package.py')
shutil.copy2(args.apk.parent / 'package.json', out / 'package.json')
result = {'apk': str(args.apk), 'apk_sha256': hashlib.sha256(args.apk.read_bytes()).hexdigest(),
          'fixture': str(args.book), 'fixture_sha256': hashlib.sha256(args.book.read_bytes()).hexdigest(),
          'serial': serial, 'avd': 'anxui-api30', 'launch': launch, 'manifest': identity,
          'backend': 'real Android API30; software CPU/GPU emulator, not physical hardware',
          'core_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
          'device': {prop: run('shell', 'getprop', prop).strip() for prop in
                     ('ro.build.version.release', 'ro.build.version.sdk', 'ro.build.fingerprint', 'ro.product.cpu.abi')},
          'display': run('shell', 'wm', 'size') + run('shell', 'wm', 'density'), 'phases': []}
source = out / 'source'
source.mkdir()
for name in ('android-smoke.py', 'android-smoke.lua', 'android_common.py'):
    shutil.copy2(Path(__file__).with_name(name), source / name)
shutil.copytree(repo / 'plugins/anxui.koplugin', source / 'anxui.koplugin')
result['source_files'] = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in source.rglob('*') if p.is_file()}
plugin_files = {str(p.relative_to(source / 'anxui.koplugin')): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (source / 'anxui.koplugin').rglob('*') if p.is_file()}
if plugin_files != package_record.get('anxui_source_files'):
    parser.error('plugin source changed since the APK identity check; rebuild and sign it first')
if result['device']['ro.build.version.sdk'] != '30' or result['device']['ro.product.cpu.abi'] != 'x86_64':
    parser.error('dedicated emulator must run the API30 x86_64 image')
external_prepared = False
try:
    target_identity()
    run('install', '-r', args.apk, timeout=180)
    run('shell', 'am', 'force-stop', package)
    run('shell', 'mkdir', '-p', '/sdcard/anx-lab')
    # An existing remote run is never reused. Keep older external settings and
    # patches intact in this run's archive before creating a clean test profile.
    run('shell', 'mkdir', remote)
    prior = run('shell', 'test', '-e', '/sdcard/koreader', check=False, raw=True)
    if prior.returncode == 0:
        run('shell', 'mv', '/sdcard/koreader', remote + '/previous-koreader')
    elif prior.returncode != 1:
        prior.check_returncode()
    result['previous_external_data'] = remote + '/previous-koreader (if present)'
    # The launcher caches extracted Lua by version. Fresh app-private data is
    # necessary when testing uncommitted revisions with the same version name.
    # The target AVD was checked above; this never operates on a personal device.
    target_identity()
    if run('shell', 'pm', 'clear', package).strip() != 'Success':
        raise RuntimeError('Android did not confirm clearing the dedicated app-private test data')
    run('shell', 'appops', 'set', '--uid', package, 'MANAGE_EXTERNAL_STORAGE', 'allow')
    run('shell', 'mkdir', '-p', remote, '/sdcard/koreader/patches')
    run('push', args.book, book)
    run('push', Path(__file__).with_name('android-smoke.lua'), '/sdcard/koreader/patches/2-anx-android-test.lua')
    external_prepared = True
    settings = out / 'settings.reader.lua'
    settings.write_text('return { color_rendering=true, language="zh_CN", keyboard_layout="en", virtual_keyboard_enabled=true, '
                        'quickstart_shown_version=9999999999, extra_plugin_paths={}, '
                        'plugins_disabled={}, start_with="filemanager", home_dir=' + json.dumps(remote) +
                        ', lastdir=' + json.dumps(remote) + ', anxui={schema=1,mode="color",startup=true} }\n')
    run('push', settings, '/sdcard/koreader/settings.reader.lua')
    previous = None
    for phase in ('ui', 'reopen'):
        phase_dir = out / phase; phase_dir.mkdir()
        control = out / 'control.json'
        phase_remote = remote + '/' + phase
        run('shell', 'mkdir', '-p', phase_remote)
        control.write_text(json.dumps({'phase': phase, 'remote': phase_remote, 'book': book,
                                       'expected': previous, 'plugin_files': plugin_files}))
        run('push', control, '/sdcard/koreader/anx-android-control.json')
        run('logcat', '-c')
        start = ['shell', 'am', 'start', '-n', component]
        if phase == 'reopen':
            start += ['-a', 'android.intent.action.VIEW', '-t', 'application/epub+zip', '-d', 'file://' + book]
        run(*start)
        deadline, handled = time.monotonic() + 480, set()
        while time.monotonic() < deadline:
            status = run('shell', 'cat', phase_remote + '/result.json', check=False).strip()
            if status:
                try: previous = json.loads(status)
                except json.JSONDecodeError: previous = None
                if previous:
                    (phase_dir / 'result.json').write_text(json.dumps(previous, ensure_ascii=False, indent=2) + '\n')
                    result['phases'].append(previous)
                    break
            request_text = run('shell', 'cat', phase_remote + '/request.json', check=False).strip()
            try: request = json.loads(request_text)
            except json.JSONDecodeError: request = None
            if request and request['id'] not in handled:
                handled.add(request['id'])
                response = {'id': request['id'], 'ok': True}
                try:
                    for action in request['actions']:
                        if action['kind'] == 'screenshot':
                            time.sleep(.5)
                            (phase_dir / (action['name'] + '.png')).write_bytes(run('exec-out', 'screencap', '-p', binary=True))
                        elif action['kind'] == 'tap':
                            run('shell', 'input', 'tap', str(action['x']), str(action['y']))
                        elif action['kind'] == 'key':
                            run('shell', 'input', 'keyevent', str(action['code']))
                        elif action['kind'] == 'background_resume':
                            background_dir = phase_dir / ('background-' + str(request['id']))
                            background_dir.mkdir(exist_ok=False)
                            transition = {'before': wait_foreground(background_dir, 'before', True)}
                            run('shell', 'input', 'keyevent', '3')
                            transition['background'] = wait_foreground(background_dir, 'background', False)
                            run('shell', 'am', 'start', '-n', component)
                            transition['resumed'] = wait_foreground(background_dir, 'resumed', True)
                            response['background_transition'] = transition
                            result.setdefault('background_transitions', []).append(transition)
                        else: raise ValueError('unsupported Android test input')
                except (subprocess.SubprocessError, ValueError, OSError, RuntimeError) as error:
                    response = {'id': request['id'], 'ok': False, 'error': str(error)}
                response_file = out / 'response.json'; response_file.write_text(json.dumps(response))
                run('push', response_file, phase_remote + '/response.json.tmp')
                run('shell', 'mv', phase_remote + '/response.json.tmp', phase_remote + '/response.json')
                (phase_dir / ('input-' + str(request['id']) + '.json')).write_text(json.dumps({'request': request, 'response': response}, indent=2))
            time.sleep(.3)
        else:
            raise TimeoutError('Android ' + phase + ' phase exceeded 480 seconds')
        (phase_dir / 'logcat.log').write_text(run('logcat', '-d', '-v', 'threadtime'))
        run('shell', 'am', 'force-stop', package)
        if not previous['passed']: raise RuntimeError(previous.get('error', 'Android assertion failed'))
    run('pull', remote, out / 'device-data')
    result['passed'] = len(result['phases']) == 2 and all(p['passed'] for p in result['phases'])
except Exception as error:
    result['passed'], result['error'] = False, str(error)
    try:
        (out / 'failure-logcat.log').write_text(run('logcat', '-d', '-v', 'threadtime'))
        (out / 'failure.png').write_bytes(run('exec-out', 'screencap', '-p', binary=True))
    except Exception:
        pass
finally:
    if external_prepared:
        try:
            target_identity()
            run('shell', 'am', 'force-stop', package)
            run('shell', 'mv', '/sdcard/koreader/patches/2-anx-android-test.lua',
                '/sdcard/koreader/patches/2-anx-android-test.lua.disabled')
            result['cleanup'] = 'test app stopped; automation patch retained with .disabled suffix'
        except Exception as error:
            result['cleanup_error'] = str(error)
            result['passed'] = False
    result['commands'] = commands
    (out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'passed': result['passed'], 'result': str(out / 'result.json')}))
raise SystemExit(0 if result['passed'] else 1)
