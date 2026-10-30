#!/usr/bin/env python3
"""Package local Anx UI source and installation files, with explicit verification scope."""

import argparse
import hashlib
import json
from pathlib import Path
import posixpath
import re
import subprocess
import zipfile


def submodule_revisions(lines):
    revisions = {}
    for line in lines:
        match = re.fullmatch(r' ([0-9a-f]{40}) (\S+)(?: .*)?', line)
        if not match:
            raise ValueError('uninitialized, conflicted or changed submodule: ' + line)
        revision, path = match.groups()
        if path in revisions:
            raise ValueError('duplicate submodule: ' + path)
        revisions[path] = revision
    return revisions


def external_core_links(members, tracked_core_files):
    external = []
    for name, data in members.items():
        if not name.endswith('.md'):
            continue
        for link in re.findall(r'\]\(([^)\s]+)\)', data.decode('utf-8')):
            if link.startswith(('/', '#')) or re.match(r'[A-Za-z][A-Za-z0-9+.-]*:', link):
                continue
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), link.split('#')[0]))
            if target in members:
                continue
            if target not in tracked_core_files:
                raise ValueError('unresolved relative document link: ' + name + ' -> ' + link)
            external.append({'document': name, 'link': link, 'core_path': target})
    return external


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--stage', choices=('snapshot', 'linux-candidate'), default='snapshot')
    parser.add_argument('--output-root', type=Path, default=Path('/data/koreader-anx-work/artifacts'),
                        help='Parent for a new run directory; existing results are never overwritten')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id):
        parser.error('run-id must contain only letters, digits, underscores or hyphens')
    repo = Path(__file__).resolve().parents[3]
    docs = repo / 'doc/anx-style-ui'
    state = json.loads((docs / 'execution-state.json').read_text())
    if args.stage == 'linux-candidate' and state['gates']['G5-local']['status'] != 'verified':
        parser.error('linux-candidate requires the verified G5-local gate; use snapshot for incomplete work')
    out = args.output_root / args.run_id
    plugin = sorted((repo / 'plugins/anxui.koplugin').rglob('*.lua'))
    docs_files = sorted(p for p in docs.rglob('*') if p.is_file()
                        and (p.suffix in ('.md', '.json', '.lua', '.py') or p.name == '.gitignore'))
    tests = sorted((repo / 'spec/unit').glob('anxui_*_spec.lua'))
    files = sorted(set(plugin + docs_files + tests + [repo / 'COPYING']))
    sha = lambda data: hashlib.sha256(data).hexdigest()
    # Read once: a concurrent edit cannot create inconsistent ZIPs and manifests.
    contents = {str(p.relative_to(repo)): p.read_bytes() for p in files}
    core_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    submodules = subprocess.check_output(['git', 'submodule', 'status', '--recursive'],
                                        cwd=repo, text=True).splitlines()
    tracked_core_files = set(subprocess.check_output(['git', 'ls-files'], cwd=repo, text=True).splitlines())
    tracked_core_files = {name for name in tracked_core_files if (repo / name).is_file()}
    if args.stage == 'linux-candidate':
        for batch in ('W31', 'W33'):
            record = state['batches'][batch]
            snapshot = record.get('source_snapshot')
            if record['status'] != 'verified' or not snapshot:
                parser.error(batch + ' must have verified status and a source snapshot')
            verified = json.loads(Path(snapshot).read_text())
            if batch == 'W31':
                if verified.get('core_head') != core_head:
                    parser.error('W31 verified core HEAD differs from the current core')
                expected_submodules = verified.get('submodules')
                if not isinstance(expected_submodules, list) or not expected_submodules:
                    parser.error('W31 evidence has no verified submodule identity')
                try:
                    if submodule_revisions(expected_submodules) != submodule_revisions(submodules):
                        parser.error('W31 verified submodule revisions differ from the current checkout')
                except ValueError as error:
                    parser.error(str(error))
            verified = verified.get('source_files', verified)
            current_plugin_files = {str(path.relative_to(repo)) for path in plugin}
            verified_plugin_files = {name for name in verified
                                     if name.startswith('plugins/anxui.koplugin/') and name.endswith('.lua')}
            if current_plugin_files != verified_plugin_files:
                missing = sorted(verified_plugin_files - current_plugin_files)
                added = sorted(current_plugin_files - verified_plugin_files)
                parser.error(batch + ' plugin file set differs from verified evidence'
                             + '; missing=' + repr(missing) + '; added=' + repr(added))
            for path in plugin:
                name = str(path.relative_to(repo))
                if verified.get(name) != sha(contents[name]):
                    parser.error(batch + ' evidence is stale or incomplete for ' + name)
        # Ignore newly added plugin/docs and generated untracked build files, but
        # reject tracked changes in the core and every initialized submodule.
        status_args = ['status', '--porcelain=v1', '--untracked-files=no', '--ignore-submodules=untracked']
        if subprocess.check_output(['git', *status_args], cwd=repo, text=True).strip():
            parser.error('linux-candidate requires a clean tracked core working tree and index')
        submodule_status = subprocess.check_output(
            ['git', 'submodule', 'foreach', '--quiet', '--recursive', 'git ' + ' '.join(status_args)],
            cwd=repo, text=True)
        if submodule_status.strip():
            parser.error('linux-candidate requires clean tracked submodule working trees and indexes')
    identity = {
        'stage': args.stage,
        'core_head': core_head,
        'core_describe': subprocess.check_output(['git', 'describe', '--match=v[0-9]*', 'HEAD'], cwd=repo, text=True).strip(),
        'submodules': submodules,
        'files': {name: sha(data) for name, data in contents.items()},
        'external_core_links': external_core_links(contents, tracked_core_files),
        'plugin_files': {name: sha(data) for name, data in contents.items() if name.startswith('plugins/')},
        'gates_at_packaging': state['gates'],
        'scope': 'Local source/plugin distribution only. Android, hardware and network services require their own evidence.',
        'optional_assistant_bundled': False,
        'user_settings_bundled': False,
    }
    manifest = (json.dumps(identity, ensure_ascii=False, indent=2) + '\n').encode()
    out.mkdir(parents=True, exist_ok=False)
    (out / 'manifest.json').write_bytes(manifest)

    def archive(name, members):
        path = out / name
        archive_identity = {**identity, 'archive': name,
                            'files': {filename: sha(data) for filename, data in members.items()},
                            'external_core_links': external_core_links(members, tracked_core_files)}
        archive_manifest = (json.dumps(archive_identity, ensure_ascii=False, indent=2) + '\n').encode()
        with zipfile.ZipFile(path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as package:
            for filename, data in sorted({**members, 'anx-manifest.json': archive_manifest}.items()):
                info = zipfile.ZipInfo(filename, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                package.writestr(info, data)
        with zipfile.ZipFile(path) as package:
            assert package.testzip() is None
            assert set(package.namelist()) == set(members) | {'anx-manifest.json'}
            assert json.loads(package.read('anx-manifest.json'))['files'] == archive_identity['files']
            assert {n: sha(package.read(n)) for n in members} == {n: sha(d) for n, d in members.items()}
        return {'path': str(path), 'bytes': path.stat().st_size, 'sha256': sha(path.read_bytes())}

    install = {n: d for n, d in contents.items() if n.startswith('plugins/') or n == 'COPYING'
               or (n.startswith('doc/anx-style-ui/')
                   and (Path(n).suffix == '.md' or n == 'doc/anx-style-ui/execution-state.json'))}
    artifacts = [archive('anxui-plugin.zip', install), archive('anxui-source-and-verification.zip', contents)]
    report = {'stage': args.stage, 'manifest': str(out / 'manifest.json'), 'artifacts': artifacts,
              'verification': 'ZIP CRC and all unpacked file hashes checked; no install/publish action performed'}
    (out / 'artifacts.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    (out / 'SHA256SUMS').write_text(''.join(f"{item['sha256']}  {Path(item['path']).name}\n" for item in artifacts))
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
