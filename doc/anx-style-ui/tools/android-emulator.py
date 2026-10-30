#!/usr/bin/env python3
"""Start/probe/stop only the dedicated Anx API30 software-emulated test device."""
import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import secrets
import socket
import subprocess
from android_common import owned_avd, owned_process, process_start_ticks, OWNER, IMAGE

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=('start', 'probe', 'stop'))
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
work = Path('/data/koreader-anx-work')
sdk = repo / 'base/toolchain/android-sdk-linux'
avd_root = work / 'android-avd'
avd_root.mkdir(parents=True, exist_ok=True)
avd = avd_root / 'anxui-api30.avd'
state = avd_root / 'emulator.json'
serial = 'emulator-5584'
environment = os.environ.copy()
environment.update(ANDROID_USER_HOME=str(work / 'android-sdk-user'), ANDROID_AVD_HOME=str(avd_root),
                   ANDROID_SDK_ROOT=str(sdk), ADB_VENDOR_KEYS=str(work / 'android-adb'))
adb = sdk / 'platform-tools/adb'

def run(command, timeout=30, **kwargs):
    return subprocess.run(list(map(str, command)), env=environment, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kwargs)

if args.action == 'start':
    if state.exists():
        old = json.loads(state.read_text())
        try:
            os.kill(old['pid'], 0)
        except ProcessLookupError:
            pass
        else:
            raise SystemExit('Dedicated emulator process is already running; probe it instead.')
    for port in (5584, 5585):
        with socket.socket() as check:
            check.bind(('127.0.0.1', port))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    evidence = work / 'evidence/W35/emulator' / stamp
    evidence.mkdir(parents=True, exist_ok=False)
    image = sdk / 'system-images/android-30/default/x86_64/system.img'
    if not image.exists():
        raise SystemExit('Install the pinned API30 x86_64 system image first.')
    if not avd.exists():
        if (avd_root / 'anxui-api30.ini').exists():
            raise SystemExit('AVD index already exists without the expected data directory; inspect it first.')
        create = run([sdk / 'cmdline-tools/latest/bin/avdmanager', 'create', 'avd', '--name', 'anxui-api30',
                      '--package', 'system-images;android-30;default;x86_64', '--path', avd,
                      '--device', 'pixel_2'], input='no\n', timeout=60)
        (evidence / 'avd-create.log').write_text(create.stdout)
        create.check_returncode()
        config = avd / 'config.ini'
        lines = dict(line.split('=', 1) for line in config.read_text().splitlines() if '=' in line)
        lines.update({'hw.lcd.width': '480', 'hw.lcd.height': '800', 'hw.lcd.density': '160',
                      'hw.ramSize': '1536', 'hw.keyboard': 'yes', 'showDeviceFrame': 'no'})
        config.write_text(''.join(key + '=' + value + '\n' for key, value in sorted(lines.items())))
        OWNER.write_text(json.dumps({'schema': 1, 'avd': str(avd), 'image': str(IMAGE),
                                     'token': secrets.token_hex(24), 'created_at': stamp}, indent=2) + '\n')
    owner = owned_avd()
    command = [sdk / 'emulator/emulator', '-avd', 'anxui-api30', '-port', '5584',
               '-accel', 'off', '-gpu', 'swiftshader', '-no-window', '-no-audio', '-no-boot-anim',
               '-no-snapshot', '-no-metrics', '-memory', '1536', '-cores', '2',
               '-camera-back', 'none', '-camera-front', 'none']
    with (evidence / 'emulator.log').open('w') as log:
        process = subprocess.Popen(list(map(str, command)), env=environment,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    record = {'pid': process.pid, 'serial': serial, 'evidence': str(evidence),
              'avd': str(avd), 'owner_token': owner['token'], 'start_ticks': process_start_ticks(process.pid),
              'command': list(map(str, command)), 'started_at': stamp,
              'mode': 'Android API30 x86_64, TCG CPU + SwiftShader GPU, no KVM',
              'state': 'launched; boot not yet verified'}
    state.write_text(json.dumps(record, indent=2) + '\n')
    (evidence / 'launch.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))
elif args.action == 'probe':
    data = owned_process()
    props, errors = {}, {}
    queries = [(name, ['shell', 'getprop', name]) for name in
               ('sys.boot_completed', 'ro.build.version.release', 'ro.build.version.sdk', 'ro.product.cpu.abi')]
    queries.append(('avd_name', ['emu', 'avd', 'name']))
    for name, arguments in queries:
        props[name] = ''
        try:
            result = run([adb, '-s', serial, *arguments], timeout=15)
            if result.returncode:
                errors[name] = {'kind': 'command_failed', 'returncode': result.returncode,
                                'output': result.stdout}
            else:
                value = result.stdout.strip()
                props[name] = value.splitlines()[0].strip() if name == 'avd_name' and value else value
        except subprocess.TimeoutExpired as error:
            partial = error.stdout or ''
            if isinstance(partial, bytes):
                partial = partial.decode(errors='replace')
            errors[name] = {'kind': 'timeout', 'seconds': error.timeout, 'output': partial}
        except OSError as error:
            errors[name] = {'kind': 'os_error', 'errno': error.errno, 'message': str(error)}
    if props['avd_name'] and props['avd_name'] != 'anxui-api30':
        errors['avd_name'] = {'kind': 'identity_mismatch', 'observed': props['avd_name']}
    data['properties'] = props
    data['errors'] = errors
    complete = (not errors and props['sys.boot_completed'] == '1'
                and props['ro.build.version.sdk'] == '30' and props['ro.product.cpu.abi'] == 'x86_64'
                and props['avd_name'] == 'anxui-api30')
    data['state'] = 'boot_complete' if complete else 'boot_pending'
    checked = datetime.datetime.now(datetime.timezone.utc)
    data['checked_at'] = checked.isoformat()
    serialized = json.dumps(data, indent=2) + '\n'
    state.write_text(serialized)
    (Path(data['evidence']) / ('probe-' + checked.strftime('%Y%m%dT%H%M%S%fZ') + '.json')).write_text(serialized)
    (Path(data['evidence']) / 'probe.json').write_text(serialized)
    print(json.dumps(data, indent=2))
else:
    data = owned_process()
    try:
        name = run([adb, '-s', serial, 'emu', 'avd', 'name'], timeout=15)
        if name.returncode or not name.stdout or name.stdout.splitlines()[0].strip() != 'anxui-api30':
            raise RuntimeError('Dedicated AVD is not reachable on its recorded ADB serial')
        owned_process(data)
        result = run([adb, '-s', serial, 'emu', 'kill'], timeout=15)
        result.check_returncode()
        message = result.stdout.strip()
    except (subprocess.SubprocessError, RuntimeError) as error:
        # Re-check the PID start time before terminating only our process group.
        owned_process(data)
        if os.getpgid(data['pid']) != data['pid']:
            raise RuntimeError('Dedicated emulator no longer owns its process group') from error
        os.killpg(data['pid'], signal.SIGTERM)
        message = 'Sent SIGTERM to the verified dedicated emulator process group'
    data['state'] = 'stop_requested'
    state.write_text(json.dumps(data, indent=2) + '\n')
    print(message)
