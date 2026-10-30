#!/usr/bin/env python3
"""Create and inspect a development-signed APK from an existing pinned build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import zipfile
from android_common import apk_badging, check_apk_identity

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--abi', choices=('arm64', 'x86_64'), required=True)
parser.add_argument('--run-id', required=True)
parser.add_argument('--stage', choices=('intermediate', 'candidate'), default='intermediate')
parser.add_argument('--anx-revision', type=int, default=0,
                    help='Local update revision used for both VERSION and ANDROID_VERSION during the build')
args = parser.parse_args()
if not 0 <= args.anx_revision <= 999:
    parser.error('anx-revision must be between 0 and 999')
if not args.run_id or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.run_id):
    parser.error('run-id must be a simple directory name')
repo = Path(__file__).resolve().parents[3]
work = Path('/data/koreader-anx-work')
out = work / 'evidence/W34/packages' / args.run_id
out.mkdir(parents=True, exist_ok=False)
sdk = repo / 'base/toolchain/android-sdk-linux'
build_tools = sdk / 'build-tools/34.0.0'
triplet = 'aarch64' if args.abi == 'arm64' else 'x86_64'
apk = repo / f'koreader-android-{triplet}-unknown-linux-android21/luajit-launcher/outputs/apk/{args.abi}Rocks/release/NativeActivity.apk'
if not apk.is_file():
    parser.error('build the requested APK first')

def run(command, logfile):
    with (out / logfile).open('w') as log:
        subprocess.run(list(map(str, command)), cwd=repo, check=True, stdout=log, stderr=subprocess.STDOUT)

keydir = work / 'android-signing'
if keydir.is_symlink():
    parser.error('signing directory must not be a symlink')
keydir.mkdir(mode=0o700, exist_ok=True)
keydir.chmod(0o700)
keystore, password = keydir / 'anx-development.p12', keydir / 'password'
if keystore.is_symlink() or password.is_symlink():
    parser.error('signing files must not be symlinks')
if not keystore.exists():
    if password.exists():
        parser.error('password exists without keystore; inspect the previous interrupted signing setup')
    descriptor = os.open(password, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(secrets.token_urlsafe(32))
    run(['keytool', '-genkeypair', '-keystore', keystore, '-storetype', 'PKCS12',
         '-storepass:file', password, '-alias', 'anx-development', '-keyalg', 'RSA',
         '-keysize', '3072', '-validity', '3650', '-dname', 'CN=Anx UI local development'], 'key-generation.log')
    keystore.chmod(0o600)
if not password.is_file():
    parser.error('signing password file is missing')
keystore.chmod(0o600)
password.chmod(0o600)

unsigned = out / f'koreader-anx-{args.abi}-unsigned.apk'
aligned = out / f'koreader-anx-{args.abi}-aligned.apk'
signed = out / f'koreader-anx-{args.abi}-development.apk'
shutil.copy2(apk, unsigned)
run([build_tools / 'zipalign', '-p', '-f', '4', unsigned, aligned], 'zipalign.log')
run([build_tools / 'apksigner', 'sign', '--ks', keystore, '--ks-key-alias', 'anx-development',
     '--ks-pass', 'file:' + str(password), '--out', signed, aligned], 'sign.log')
run([build_tools / 'apksigner', 'verify', '--verbose', '--print-certs', signed], 'verify-signature.log')
run([build_tools / 'aapt', 'dump', 'badging', signed], 'manifest.log')
run([build_tools / 'aapt', 'dump', 'permissions', signed], 'permissions.log')
identity = apk_badging((out / 'manifest.log').read_text())
expected_abi = 'arm64-v8a' if args.abi == 'arm64' else 'x86_64'
check_apk_identity(identity, expected_abi)
describe = subprocess.check_output(['git', 'describe', '--match=v[0-9]*', 'HEAD'], cwd=repo, text=True).strip()
expected_version = subprocess.check_output(['./tools/describe.sh'], cwd=repo, text=True).splitlines()[0]
if args.anx_revision:
    expected_version += '-anxui' + str(args.anx_revision)
expected_code = (int(subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], cwd=repo, text=True))
                 + args.anx_revision) * 10 + (2 if args.abi == 'arm64' else 4)
expected_git_rev = expected_version + '_android'
assets = out / 'assets'
assets.mkdir()
with zipfile.ZipFile(signed) as package:
    module = package.read('assets/module/koreader.7z')
    module_version = package.read('assets/module/version.txt').decode().strip()
    zip_abis = sorted({name.split('/')[1] for name in package.namelist() if name.startswith('lib/') and name.endswith('.so')})
(assets / 'koreader.7z').write_bytes(module)
run(['7z', 'x', '-y', '-o' + str(assets), assets / 'koreader.7z', 'plugins/anxui.koplugin/*', 'git-rev'], 'inspect-plugin.log')
git_rev = (assets / 'git-rev').read_text().strip()
source = repo / 'plugins/anxui.koplugin'
packaged = assets / 'plugins/anxui.koplugin'
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
source_hashes = {str(p.relative_to(source)): sha(p) for p in source.rglob('*') if p.is_file()}
packaged_hashes = {str(p.relative_to(packaged)): sha(p) for p in packaged.rglob('*') if p.is_file()}
metadata = {
    'stage': args.stage, 'abi': args.abi, 'apk': str(signed), 'sha256': sha(signed),
    'bytes': signed.stat().st_size, 'signature': 'local development certificate; not an upstream release signature',
    'source_apk': str(apk), 'unsigned_sha256': sha(unsigned),
    'manifest': identity, 'zip_native_abis': zip_abis,
    'git_describe': describe, 'module_version': module_version, 'git_rev': git_rev,
    'expected_version_name': expected_version, 'expected_version_code': expected_code,
    'anx_revision': args.anx_revision,
    'expected_git_rev': expected_git_rev,
    'version_matches_current_source': identity.get('versionName') == expected_version
        and identity.get('versionCode') == str(expected_code)
        and module_version == expected_git_rev and git_rev == expected_git_rev,
    'abi_matches_requested': zip_abis == [expected_abi],
    'core_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
    'submodules': subprocess.check_output(['git', 'submodule', 'status', '--recursive'], cwd=repo, text=True).splitlines(),
    'anxui_source_files': source_hashes, 'anxui_packaged_files': packaged_hashes,
    'plugin_matches_current_source': source_hashes == packaged_hashes,
    'runtime_verification': 'not implied by signing; see W35/W36 evidence',
}
(out / 'source.diff').write_bytes(subprocess.check_output(['git', 'diff', '--binary'], cwd=repo))
metadata['passed'] = all(metadata[key] for key in ('plugin_matches_current_source', 'version_matches_current_source', 'abi_matches_requested'))
(out / 'package.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'package': str(out / 'package.json'), 'passed': metadata['passed']}))
if not metadata['passed']:
    raise SystemExit(2)
