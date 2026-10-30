"""Shared identity checks for the isolated Android validation tools."""
import json
import os
from pathlib import Path
import re
import shlex

REPO = Path(__file__).resolve().parents[3]
WORK = Path('/data/koreader-anx-work')
SDK = REPO / 'base/toolchain/android-sdk-linux'
AVD_ROOT = WORK / 'android-avd'
AVD_NAME = 'anxui-api30'
AVD = AVD_ROOT / (AVD_NAME + '.avd')
STATE = AVD_ROOT / 'emulator.json'
SERIAL = 'emulator-5584'
PACKAGE = 'org.koreader.launcher'
IMAGE = SDK / 'system-images/android-30/default/x86_64'
OWNER = AVD / '.anxui-owner.json'


def ini(path):
    return dict(tuple(part.strip() for part in line.split('=', 1)) for line in path.read_text().splitlines()
                if '=' in line and not line.lstrip().startswith('#'))


def owned_avd():
    """Never adopt or erase an existing AVD without our creation marker."""
    if any(path.is_symlink() for path in (AVD_ROOT, AVD, OWNER, AVD / 'config.ini', AVD_ROOT / (AVD_NAME + '.ini'))):
        raise RuntimeError('Dedicated AVD ownership paths must not be symlinks')
    owner = json.loads(OWNER.read_text())
    if (owner.get('schema') != 1 or owner.get('avd') != str(AVD)
            or owner.get('image') != str(IMAGE) or not owner.get('token')):
        raise RuntimeError('Dedicated AVD ownership marker is invalid')
    index, config = ini(AVD_ROOT / (AVD_NAME + '.ini')), ini(AVD / 'config.ini')
    image = Path(config.get('image.sysdir.1', ''))
    if not image.is_absolute():
        image = SDK / image
    if (Path(index.get('path', '')).resolve() != AVD.resolve()
            or index.get('target') != 'android-30'
            or image.resolve() != IMAGE.resolve()
            or config.get('abi.type') != 'x86_64'
            or config.get('tag.id') != 'default'
            or config.get('AvdId', AVD_NAME) != AVD_NAME):
        raise RuntimeError('Dedicated AVD path or system-image configuration changed')
    return owner


def process_start_ticks(pid):
    # The command name in /proc/PID/stat may contain spaces or parentheses.
    return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]


def owned_process(record=None):
    """Bind the ADB serial to the process and AVD created by our launcher."""
    owner = owned_avd()
    record = record if record is not None else json.loads(STATE.read_text())
    pid = record.get('pid')
    if (not isinstance(pid, int) or pid <= 1 or record.get('serial') != SERIAL
            or record.get('avd') != str(AVD) or record.get('owner_token') != owner['token']
            or record.get('start_ticks') != process_start_ticks(pid)):
        raise RuntimeError('Dedicated emulator process identity does not match the launch record')
    command = Path(f'/proc/{pid}/cmdline').read_bytes().decode().rstrip('\0').split('\0')
    for flag, value in (('-avd', AVD_NAME), ('-port', '5584')):
        if flag not in command or command.index(flag) + 1 >= len(command) or command[command.index(flag) + 1] != value:
            raise RuntimeError('Recorded PID is not the dedicated emulator')
    environment = dict(part.split(b'=', 1) for part in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0') if b'=' in part)
    if environment.get(b'ANDROID_AVD_HOME') != os.fsencode(AVD_ROOT):
        raise RuntimeError('Recorded emulator uses another AVD directory')
    return record


def apk_badging(text):
    """Extract machine-readable identity while retaining raw aapt evidence."""
    package_lines = [line for line in text.splitlines() if line.startswith('package: ')]
    if len(package_lines) != 1:
        raise ValueError('aapt did not return exactly one package identity')
    identity = dict(re.findall(r"([A-Za-z][A-Za-z0-9]*)='([^']*)'", package_lines[0]))
    native = [line.partition(':')[2].strip() for line in text.splitlines() if line.startswith('native-code:')]
    identity['native_abis'] = shlex.split(native[0]) if len(native) == 1 else []
    identity['permissions'] = [dict(re.findall(r"([A-Za-z][A-Za-z0-9]*)='([^']*)'", line))
                               for line in text.splitlines() if line.startswith('uses-permission:')]
    for field in ('sdkVersion', 'targetSdkVersion'):
        values = [line.partition(':')[2].strip(" '") for line in text.splitlines() if line.startswith(field + ':')]
        identity[field] = values[0] if len(values) == 1 else None
    return identity


def check_apk_identity(identity, abi):
    if identity.get('name') != PACKAGE or identity.get('native_abis') != [abi]:
        raise RuntimeError('APK must be the requested ABI of org.koreader.launcher Rocks release')
    permissions = {entry.get('name') for entry in identity['permissions']}
    if 'android.permission.MANAGE_EXTERNAL_STORAGE' not in permissions:
        raise RuntimeError('APK lacks the API30 file-access permission required by this test')
