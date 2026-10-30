#!/usr/bin/env python3
"""Collect reproducible W31 measurements from the real isolated SDL application.

The full suite must run after source freeze and competing builds have stopped.
Pilot runs exercise the harness only and cannot pass the final W31 gate.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import time

WORK = Path('/data/koreader-anx-work')
REPO = Path(__file__).resolve().parents[3]
MIB = 1024 * 1024
# Runtime upvalue evidence in W31/owner-diag-02 identified these exact native
# closures. This is an attribution of an existing baseline issue, not a general
# allowance for one retained owner or a change to any memory budget.
NATIVE_INITIAL_FM_ROOTS = (
    ('cloudstorage', 'get', '@plugins/cloudstorage.koplugin/main.lua', 32),
    ('cloudstorage', 'set', '@plugins/cloudstorage.koplugin/main.lua', 36),
    ('cloudstorage_upload', 'get', '@plugins/cloudstorage.koplugin/main.lua', 44),
    ('cloudstorage_upload', 'set', '@plugins/cloudstorage.koplugin/main.lua', 48),
    ('exporter', 'get', '@plugins/exporter.koplugin/main.lua', 109),
    ('exporter', 'set', '@plugins/exporter.koplugin/main.lua', 112),
    ('movetoarchive', 'get', '@plugins/movetoarchive.koplugin/main.lua', 30),
    ('movetoarchive', 'set', '@plugins/movetoarchive.koplugin/main.lua', 34),
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def read_jsonl(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * fraction) - 1] if ordered else None


def stats(values):
    return {'n': len(values), 'p50_ms': percentile(values, .5), 'p95_ms': percentile(values, .95),
            'max_ms': max(values) if values else None}


def competing_builds(exclude_process_group=None, exclude_session=None, own_processes=None):
    # This is a bounded observation of known competing workloads, not proof
    # that an entire shared host is idle. The root coordinator must also attest
    # that other builds, test runners and emulators have been stopped.
    names = {'cc1', 'cc1plus', 'clang', 'clang++', 'gcc', 'g++', 'ninja', 'rustc', 'javac',
             'java', 'gradle', 'emulator', 'qemu-system-x86', 'qemu-system-aar', 'luajit', 'Xvfb'}
    found = []
    for entry in Path('/proc').iterdir():
        if entry.name.isdecimal():
            try:
                name = (entry / 'comm').read_text().strip()
                fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
                state, parent, group, session = fields[0], int(fields[1]), int(fields[2]), int(fields[3])
                if name in names and state not in ('Z', 'T', 't'):
                    row = {'pid': int(entry.name), 'name': name, 'state': state, 'parent_pid': parent,
                           'process_group': group, 'session_id': session}
                    # Native cover workers call setpgid(0, 0), retaining the
                    # isolated Popen session even though their group changes.
                    if group == exclude_process_group or session == exclude_session:
                        if own_processes is not None:
                            row['excluded_as'] = 'run_session' if session == exclude_session else 'run_process_group'
                            own_processes.append(row)
                    else:
                        found.append(row)
            except (OSError, IndexError, ValueError):
                continue
    return found


def source_files():
    paths = sorted((REPO / 'plugins/anxui.koplugin').rglob('*.lua'))
    paths += [Path(__file__).resolve(), Path(__file__).with_name('performance-smoke.lua')]
    return {str(path.relative_to(REPO)): digest(path) for path in paths}


def prepare_corpus(target, count, manifest):
    """Independent paths, deliberately reused self-authored format contents."""
    target.mkdir()
    items = [item for item in manifest if 'broken' not in Path(item['path']).name]
    assert items
    rows, checked = [], set()
    for index in range(1, count + 1):
        item = items[(index - 1) % len(items)]
        original = Path(item['path'])
        if str(original) not in checked:
            if digest(original) != item['sha256']:
                raise RuntimeError('fixture source has changed: ' + str(original))
            checked.add(str(original))
        destination = target / f'Mix-{index:05d}-{original.name}'
        # A per-process fixture copy is linked within this process's own book set.
        # Never link directly to the shared source: a native writer must not be
        # able to change another run's fixture through a shared inode.
        existing = next((row for row in rows if row['source'] == str(original)), None)
        if existing:
            os.link(target / existing['name'], destination)
        else:
            shutil.copy2(original, destination)
        rows.append({'name': destination.name, 'source': str(original), 'sha256': item['sha256'],
                     'format': original.suffix.lower(), 'bytes': original.stat().st_size})
    return rows


def run_case(args, case, source, fixture_manifest):
    diagnostic_hot_memory = getattr(args, 'diagnostic_hot_memory', False)
    if diagnostic_hot_memory and args.suite == 'full':
        raise ValueError('hot memory diagnostics are forbidden in full measurements')
    name = case['name']
    runtime, evidence = args.runtime / name, args.evidence / name
    runtime.mkdir(); evidence.mkdir()
    books = runtime / 'books'
    rows = prepare_corpus(books, case['count'], fixture_manifest)
    # The first fixture is the same Chinese EPUB for every reading/page sequence.
    book = books / rows[0]['name']
    assert book.suffix == '.epub'
    write_json(evidence / 'corpus.json', {
        'paths': rows, 'format_counts': dict(Counter(row['format'] for row in rows)),
        'distinct_contents': len({row['sha256'] for row in rows}),
        'note': 'Many paths reuse 13 valid self-authored fixture files (12 unique contents); not 5000 independent texts. '
                'Hardlinks occur only between copies inside this isolated run. No library-wide metadata is prefilled.',
    })
    cancel_fixture = None
    if case['action'] == 'library' and case['mode'] == 'anx':
        manifest_path = WORK / 'fixtures/performance-v1/manifest.json'
        manifest_bytes = manifest_path.read_bytes()
        stress = json.loads(manifest_bytes)
        original = Path(stress['path'])
        if digest(original) != stress['sha256'] or original.stat().st_size != stress['bytes']:
            raise RuntimeError('cancel stress fixture has changed: ' + str(original))
        destination = runtime / 'cancel-stress.pdf'
        shutil.copy2(original, destination)
        if digest(destination) != stress['sha256']:
            raise RuntimeError('cancel stress fixture copy does not match its manifest')
        cancel_fixture = {
            'fixture': stress, 'path': str(destination), 'sha256': stress['sha256'],
            'manifest_path': str(manifest_path), 'manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
            'included_in_library_count': False, 'ui_visible_page_content': False,
            'note': '独立适配器原引擎压力输入，不改变书库count，不是UI可见页内容',
        }
        write_json(evidence / 'cancel-stress-fixture.json', cancel_fixture)
    patches = runtime / 'patches'; patches.mkdir()
    shutil.copy2(args.evidence / 'source/doc/anx-style-ui/tools/performance-smoke.lua', patches / '2-anx-performance.lua')
    disabled = case['mode'] == 'classic'
    startup = case['action'] == 'startup' and not disabled
    (runtime / 'settings.reader.lua').write_text(
        'return { plugins_disabled = { anxui = ' + ('true' if disabled else 'false')
        + ' }, extra_plugin_paths = {}, color_rendering = true, language = "zh_CN", '
        + 'keyboard_layout = "en", start_with = "filemanager", quickstart_shown_version = 9999999999, '
        + 'anxui = { mode = ' + json.dumps(case['theme']) + ', startup = ' + ('true' if startup else 'false')
        + ' }, home_dir = ' + json.dumps(str(books), ensure_ascii=False)
        + ', lastdir = ' + json.dumps(str(books), ensure_ascii=False) + ' }\n'
    )
    env = os.environ.copy()
    env.pop('ANX_PERF_CANCEL_BOOK', None)
    env.pop('ANX_PERF_DIAGNOSTIC_HOT_MEMORY', None)
    if diagnostic_hot_memory:
        env['ANX_PERF_DIAGNOSTIC_HOT_MEMORY'] = '1'
    if cancel_fixture:
        env['ANX_PERF_CANCEL_BOOK'] = cancel_fixture['path']
    env.update(KO_HOME=str(runtime), PARALLEL_JOBS='1', SDL_RENDER_DRIVER='software', SDL_VIDEO_DRIVER='x11',
               ANX_PERF_ACTION=case['action'], ANX_PERF_MODE=case['mode'], ANX_PERF_EVIDENCE=str(evidence),
               ANX_PERF_BOOK=str(book), ANX_PERF_COUNT=str(case['count']), ANX_PERF_WARMUP=str(case['warmup']),
               ANX_PERF_ITERATIONS=str(case['iterations']),
               ANX_PERF_CANDIDATE=str(args.evidence / 'source/plugins/anxui.koplugin'))
    command = ['xvfb-run', '-a', '-s', '-screen 0 1440x1000x24 -nolisten tcp', './kodev', 'run', '-b',
               '-W', '540', '-H', '720', '-D', '160']
    # No explicit path for either variant: both use the configured home folder.
    busy = competing_builds()
    if busy and args.suite != 'pilot':
        raise RuntimeError('competing build processes detected; wait before final measurements: ' + str(busy))
    started = time.monotonic()
    env['ANX_PERF_LAUNCH_MONOTONIC'] = str(started)
    with (evidence / 'application.log').open('w') as log:
        process = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        observed_workloads, observed_own_processes = {}, {}
        try:
            deadline = started + case.get('timeout', 600)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, case.get('timeout', 600))
                try:
                    exit_code = process.wait(timeout=min(1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    own_processes = []
                    for row in competing_builds(exclude_process_group=process.pid, exclude_session=process.pid,
                                                own_processes=own_processes):
                        observed_workloads.setdefault((row['pid'], row['name']),
                                                     {**row, 'first_seen_seconds': time.monotonic() - started})
                    for row in own_processes:
                        observed_own_processes.setdefault((row['pid'], row['name']),
                                                        {**row, 'first_seen_seconds': time.monotonic() - started})
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait()
            exit_code = 124
    measurements = evidence / 'measurements.json'
    result = json.loads(measurements.read_text()) if measurements.exists() else {'passed': False, 'error': 'no measurements'}
    result.update(case=case, command=command, exit_code=exit_code, elapsed_seconds=time.monotonic() - started,
                  runtime=str(runtime), evidence=str(evidence), competing_builds=busy,
                  competing_workloads_during_run=list(observed_workloads.values()),
                  excluded_own_processes=list(observed_own_processes.values()),
                  exclusive_coordinator_confirmation=args.exclusive_confirmed,
                  cancel_stress_fixture=cancel_fixture,
                  cache='Fresh KO_HOME per case, shared OS page cache; hot loops reuse the case caches.',
                  samples=read_jsonl(evidence / 'samples.jsonl'), memory=read_jsonl(evidence / 'memory.jsonl'))
    contents = (evidence / 'application.log').read_text(errors='replace')
    result['execution_passed'] = result.get('passed') is True and exit_code == 0 and 'ANX_PERF_PASS' in contents
    if diagnostic_hot_memory:
        result['diagnostic_hot_memory'] = True
        result['hot_memory'] = read_jsonl(evidence / 'hot-memory.jsonl')
    result['source_unchanged'] = source_files() == source
    result['workload_isolated'] = not busy and not observed_workloads
    result['passed'] = result['execution_passed'] and result['source_unchanged'] and (
        args.suite == 'pilot' or (result['workload_isolated'] and args.exclusive_confirmed))
    grouped = defaultdict(list)
    for row in result['samples']:
        if (row.get('warmup') is not True and isinstance(row.get('kind'), str)
                and type(row.get('elapsed_ms')) in (int, float)
                and math.isfinite(row['elapsed_ms']) and row['elapsed_ms'] >= 0):
            key = row['kind'] + (':' + row['action'] if isinstance(row.get('action'), str) else '')
            grouped[key].append(row['elapsed_ms'])
    result['timings'] = {kind: stats(values) for kind, values in grouped.items()}
    write_json(evidence / 'result.json', result)
    print(name + ': ' + ('PASS' if result['passed'] else 'FAIL'), flush=True)
    return result


def case_plan(suite, themes):
    cases = []
    def add(action, theme, mode, count, number=1):
        cases.append({'name': f'{action}-{theme}-{mode}-{count}-{number:02d}', 'action': action,
                      'theme': theme, 'mode': mode, 'count': count,
                      'iterations': 10 if suite == 'pilot' else 100,
                      'warmup': 2 if suite == 'pilot' else 10})
    for theme in themes:
        if suite in ('full', 'startup', 'pilot'):
            for number in range(1, 3 if suite == 'pilot' else 21):
                for mode in ('classic', 'anx'):
                    add('startup', theme, mode, 13, number)
        if suite in ('full', 'library', 'pilot'):
            for count in ([100] if suite == 'pilot' else [1000, 5000]):
                for mode in ('classic', 'anx'):
                    add('library', theme, mode, count)
        for action in ('reader', 'stability'):
            if suite in ('full', action, 'pilot'):
                for mode in ('classic', 'anx'):
                    add(action, theme, mode, 13)
    return cases


def owner_attribution(row, mode):
    """Validate the sole proven native root without rewriting raw GC counts."""
    if not row:
        return {'valid': False, 'reason': 'missing memory snapshot'}
    raw, baseline, unexpected = (row.get(key) for key in
                                ('retained_old_owners', 'baseline_initial_fm_owners', 'unexpected_old_owners'))
    details = row.get('retained_old_owner_details')
    counts_valid = (type(raw) is int and type(baseline) is int and type(unexpected) is int
                    and baseline in (0, 1) and unexpected == 0 and raw == baseline)
    paths = []
    valid = False
    if counts_valid and baseline == 0:
        # Lua's JSON encoder writes an empty table as {}.
        valid = details == [] or details == {}
    elif counts_valid and isinstance(details, list) and len(details) == 1:
        owner = details[0]
        exact_owner = (isinstance(owner, dict) and owner.get('index') == 2 and owner.get('type') == 'FileManager'
                       and owner.get('document_present') is False
                       and owner.get('current_filemanager') is False and owner.get('current_reader') is False)
        roots = row.get('native_provider_roots')
        if isinstance(roots, list) and len(roots) == 8 and all(isinstance(root, dict) for root in roots):
            paths = [(root.get('provider'), root.get('method'), root.get('source'), root.get('line')) for root in roots]
            exact_roots = (all(path in NATIVE_INITIAL_FM_ROOTS for path in paths)
                           and len(set(paths)) == 8 and all(root.get('present') is True
                           and root.get('self_upvalue_found') is True
                           and root.get('points_to_initial_filemanager') is True for root in roots))
            plugin_state = row.get('baseline_anx_plugin_state', {})
            required_state = ('present', 'stopped', 'scope_closed', 'tasks_empty', 'windows_empty',
                              'closers_empty', 'cleanups_empty', 'refs_cleared') + tuple(
                key + '_cleared' for key in ('home', 'reader', 'reader_panel', 'reader_list', 'note_actions',
                    'notes_library', 'note_index', 'statistics_view', 'settings_view', 'assistant_view',
                    'preferences_menu', 'recovery_dialog', 'book_actions', 'book_items', 'show_pending'))
            inactive = (row.get('baseline_anx_plugin_inactive') is True and isinstance(plugin_state, dict)
                        and all(plugin_state.get(key) is True for key in required_state))
            valid = exact_owner and exact_roots and (mode != 'anx' or inactive)
    return {'valid': bool(valid), 'raw_retained_old_owners': raw,
            'baseline_initial_fm_owners': baseline, 'unexpected_old_owners': unexpected,
            'native_provider_paths': sorted(paths) if valid else paths,
            'baseline_anx_plugin_inactive': row.get('baseline_anx_plugin_inactive'),
            'baseline_anx_plugin_state': row.get('baseline_anx_plugin_state')}


def analyze(results, suite, expected_cases, completed=False, exclusive_confirmed=False):
    """Fail closed on missing evidence; partial summaries are never eligible."""
    checks, startup, known_native_retention = [], {}, []
    pilot = suite == 'pilot'
    expected = {case['name']: case for case in expected_cases}
    seen = Counter(run.get('case', {}).get('name') for run in results)
    complete = (completed and bool(expected) and len(results) == len(expected_cases)
                and seen == Counter(expected.keys()) and len(expected) == len(expected_cases))
    canonical_full = case_plan('full', ('color', 'gray'))
    full_contract = (suite == 'full' and len(expected_cases) == 96
                     and Counter(case['name'] for case in expected_cases)
                     == Counter(case['name'] for case in canonical_full)
                     and all(expected[case['name']] == case for case in canonical_full))

    def add(name, passed, **details):
        checks.append({'name': name, 'passed': bool(passed), **details})

    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0

    def measured(run, kind=None):
        return [row for row in run.get('samples', []) if row.get('warmup') is not True
                and (kind is None or row.get('kind') == kind)]

    def memory_at(run, label):
        rows = [row for row in run.get('memory', []) if row.get('label') == label]
        return rows[0] if len(rows) == 1 else None

    def check_count(run, kind, count, warmup=False):
        rows = [row for row in run.get('samples', []) if row.get('kind') == kind
                and row.get('warmup') is warmup]
        declared = run.get('warmup_counts' if warmup else 'counts', {}).get(kind)
        sequence = [row.get('iteration') for row in rows] == list(range(1, count + 1))
        valid = len(rows) == count and declared == count and sequence
        add(run['case']['name'] + '_' + kind + ('_warmup' if warmup else '') + '_count', valid,
            expected=count, observed=len(rows), declared=declared, complete_iteration_sequence=sequence)
        return valid

    for run in results:
        case = run.get('case', {})
        name, action, mode = case.get('name', '?'), case.get('action'), case.get('mode')
        add(name + '_case_contract', name in expected and case == expected[name])
        add(name + '_execution', run.get('passed') is True)
        add(name + '_raw_samples', all(finite(row.get('elapsed_ms')) and isinstance(row.get('kind'), str)
                                      and type(row.get('warmup')) is bool
                                      and type(row.get('iteration')) is int and row['iteration'] >= 1
                                      for row in run.get('samples', [])))
        if not pilot:
            add(name + '_exclusive_workload', exclusive_confirmed and run.get('workload_isolated') is True
                and run.get('exclusive_coordinator_confirmation') is True,
                before=run.get('competing_builds', []), during=run.get('competing_workloads_during_run', []))
        if action == 'startup':
            key = 'first_home_paint_ms' if mode == 'anx' else 'first_main_paint_ms'
            add(name + '_startup_measurement', finite(run.get(key)), metric=key, value=run.get(key))
            continue
        iterations = case.get('iterations', 0)
        add(name + '_sample_counts_complete', run.get('checks', {}).get('sample_counts_complete') is True)
        if action == 'reader':
            check_count(run, 'page_turn', iterations)
            check_count(run, 'page_turn', case.get('warmup', 0), warmup=True)
            rows = measured(run, 'page_turn')
            add(name + '_relative_page_path', bool(rows) and all(row.get('delta') in (-1, 1)
                and finite(row.get('page')) for row in rows))
        elif action == 'stability':
            for kind in ('book_open', 'book_return'):
                check_count(run, kind, iterations)
                check_count(run, kind, case.get('warmup', 0), warmup=True)
            if mode == 'anx':
                for kind in ('tool_open', 'tool_close'):
                    check_count(run, kind, iterations)
                    check_count(run, kind, case.get('warmup', 0), warmup=True)
                    actions = Counter(row.get('action') for row in measured(run, kind))
                    expected_actions = {action: iterations // 5 for action in
                                        ('reader_panel', 'toc', 'notes', 'statistics', 'settings')}
                    add(name + '_' + kind + '_action_identity', actions == expected_actions,
                        observed=dict(actions), expected=expected_actions)
        elif action == 'library' and mode == 'anx':
            for kind in ('search', 'clear_search', 'page', 'sort', 'layout'):
                check_count(run, kind, iterations // 5)
            check_count(run, 'hot_home', min(20, iterations))
            for kind in ('note_index_cancel', 'cover_cancel', 'metadata_cancel'):
                check_count(run, kind, 1)
            add(name + '_library_actions_count', run.get('counts', {}).get('library_actions') == iterations,
                expected=iterations, declared=run.get('counts', {}).get('library_actions'))
            hot = [row['elapsed_ms'] for row in measured(run, 'hot_home') if finite(row.get('elapsed_ms'))]
            add(name + '_hot_home_budget', bool(hot) and max(hot) <= 500, **stats(hot), limit_ms=500)
            limit = (24 if case.get('theme') == 'color' else 8) * MIB
            peak = run.get('cover_peak_reserved_bytes')
            add(name + '_covers', finite(peak) and 0 < peak <= limit and run.get('cover_decode_count', 0) > 0
                and run.get('checks', {}).get('cover_decode_observed') is True,
                peak_reserved_bytes=peak, decoded=run.get('cover_decode_count'), limit_bytes=limit)
            for key in ('cover_worker_cancel', 'metadata_inflight_cancel', 'note_index_cancel'):
                add(name + '_' + key, run.get('checks', {}).get(key) is True)
        if mode == 'anx':
            # A slow sort, cancel or individual tool cannot be hidden amongst
            # many fast operations of a different kind.
            ordinary = defaultdict(list)
            for row in measured(run):
                kind = row.get('kind')
                if kind in ('search', 'clear_search', 'page', 'sort', 'layout', 'tool_open', 'tool_close',
                            'note_index_cancel', 'cover_cancel', 'metadata_cancel') and finite(row.get('elapsed_ms')):
                    key = kind + (':' + row['action'] if isinstance(row.get('action'), str) else '')
                    ordinary[key].append(row['elapsed_ms'])
            for kind, values in ordinary.items():
                timing = stats(values)
                add(name + '_' + kind + '_p95', timing['p95_ms'] <= 150, **timing, limit_ms=150)
            idle = run.get('idle', {})
            add(name + '_idle', idle.get('seconds', 0) >= 5 and idle.get('anx_dirty_calls') == 0, **idle)
        if action == 'stability':
            warm, end, final = (memory_at(run, label) for label in ('warm', 'cycles_complete', 'final'))
            add(name + '_stability_memory_present', all((warm, end, final)))
            owner_rows = {label: owner_attribution(row, mode) for label, row in
                          (('warm', warm), ('cycles_complete', end), ('final', final))}
            owners_valid = (all(row['valid'] for row in owner_rows.values())
                            and len({row.get('baseline_initial_fm_owners') for row in owner_rows.values()}) == 1)
            add(name + '_unexpected_old_owners_released', owners_valid
                and run.get('checks', {}).get('unexpected_old_owners_released') is True,
                snapshots=owner_rows,
                rule='Zero unexpected owners. Only the exact initial closed FileManager pinned by all 8 proven native closures is classified separately.')
            if owners_valid and owner_rows['final']['baseline_initial_fm_owners'] == 1:
                known_native_retention.append({
                    'case': name, 'theme': case.get('theme'), 'mode': mode,
                    'classification': '原版已有失败', 'baseline_initial_fm_owners': 1,
                    'raw_retained_old_owners': {label: row['raw_retained_old_owners'] for label, row in owner_rows.items()},
                    'native_provider_paths': owner_rows['final']['native_provider_paths'],
                    'baseline_anx_plugin_inactive': owner_rows['final']['baseline_anx_plugin_inactive'],
                    'note': 'Native shortcut callbacks retain the first closed FileManager. Raw retention remains 1; no claim of exception-free Q04 object collection.',
                })
            add(name + '_windows_released', bool(warm and end and final)
                and warm.get('windows') == end.get('windows') == final.get('windows')
                and end.get('retained_old_windows') == final.get('retained_old_windows') == 0
                and run.get('checks', {}).get('windows_restored') is True,
                warm_count=warm.get('windows') if warm else None, final_count=final.get('windows') if final else None,
                end_old_windows=end.get('retained_old_windows') if end else None,
                final_old_windows=final.get('retained_old_windows') if final else None)
            if mode == 'anx':
                add(name + '_scope_cleanup', run.get('checks', {}).get('scope_cleanup') is True)
                add(name + '_baseline_anx_plugin_inactive', owners_valid
                    and (owner_rows['final']['baseline_initial_fm_owners'] == 0
                         or run.get('checks', {}).get('baseline_anx_plugin_inactive') is True))
            if warm and end and final:
                for field in ('rss_bytes', 'lua_bytes'):
                    valid = all(finite(row.get(field)) for row in (warm, end, final))
                    tail = [row.get(field) for row in run.get('memory', []) if row.get('label', '').startswith('cycle_')][-5:]
                    enough = len(tail) >= 5 and all(finite(value) for value in tail)
                    growth = enough and tail[-1] > tail[0] and all(b >= a for a, b in zip(tail, tail[1:]))
                    limit = max(2 * MIB, warm[field] * .05) if valid else None
                    delta = max(end[field], final[field]) - warm[field] if valid else None
                    add(name + '_' + field + '_stability', valid and delta <= limit and not growth and (pilot or enough),
                        baseline_bytes=warm.get(field), delta_bytes=delta, limit_bytes=limit,
                        last_five_bytes=tail, nondecreasing_with_net_growth=growth,
                        tail_sample_requirement='5 post-warmup periodic samples; reduced pilot may have fewer')

    for theme in sorted({case['theme'] for case in expected_cases}):
        variants = {mode: [r for r in results if r.get('case', {}).get('theme') == theme
                          and r.get('case', {}).get('mode') == mode] for mode in ('classic', 'anx')}
        stability_expected = {case['mode'] for case in expected_cases
                              if case['theme'] == theme and case['action'] == 'stability'}
        if stability_expected and (not pilot or stability_expected == {'classic', 'anx'}):
            pair = {mode: next((run for run in variants[mode] if run['case']['action'] == 'stability'), None)
                    for mode in ('classic', 'anx')}
            matching = bool(pair['classic'] and pair['anx'])
            compared = {}
            for label in ('warm', 'cycles_complete', 'final'):
                rows = {mode: owner_attribution(memory_at(run, label), mode) if run
                        else owner_attribution(None, mode) for mode, run in pair.items()}
                same = (all(row['valid'] for row in rows.values())
                        and rows['classic'].get('baseline_initial_fm_owners') == rows['anx'].get('baseline_initial_fm_owners')
                        and rows['classic'].get('native_provider_paths') == rows['anx'].get('native_provider_paths'))
                matching = matching and same
                compared[label] = rows
            add(theme + '_native_retention_matches_classic', matching, snapshots=compared,
                rule='Identical exact native initial-owner reference paths and counts in both variants; no blanket owner-count allowance.')
        for mode, runs in variants.items():
            values = [r.get('first_home_paint_ms' if mode == 'anx' else 'first_main_paint_ms')
                      for r in runs if r['case']['action'] == 'startup']
            values = [value for value in values if finite(value)]
            wanted = sum(case['theme'] == theme and case['mode'] == mode and case['action'] == 'startup'
                         for case in expected_cases)
            if wanted:
                startup[theme + '_' + mode] = {**stats(values), 'raw_ms': values}
                add(theme + '_' + mode + '_startup_count', len(values) == wanted, expected=wanted, observed=len(values))
        classic_read = next((r for r in variants['classic'] if r['case']['action'] == 'reader'), None)
        anx_read = next((r for r in variants['anx'] if r['case']['action'] == 'reader'), None)
        if any(case['theme'] == theme and case['action'] == 'reader' for case in expected_cases):
            first = measured(classic_read, 'page_turn') if classic_read else []
            second = measured(anx_read, 'page_turn') if anx_read else []
            valid = first and second and all(finite(row.get('elapsed_ms')) for row in first + second)
            classic = percentile([row['elapsed_ms'] for row in first], .95) if valid else None
            actual = percentile([row['elapsed_ms'] for row in second], .95) if valid else None
            limit = max(classic * 1.10, classic + 20) if valid else None
            same = bool(first and second) and [(row.get('delta'), row.get('page')) for row in first] == [
                (row.get('delta'), row.get('page')) for row in second]
            add(theme + '_page_turn_p95', valid and same and actual <= limit,
                classic_p95_ms=classic, anx_p95_ms=actual, limit_ms=limit, identical_page_sequence=same)
        counts = {case['count'] for case in expected_cases if case['theme'] == theme and case['action'] == 'library'}
        for count in sorted(counts):
            pair = {mode: next((r for r in runs if r['case']['action'] == 'library' and r['case']['count'] == count), None)
                    for mode, runs in variants.items()}
            base = memory_at(pair['classic'], 'library_settled') if pair['classic'] else None
            interaction = memory_at(pair['anx'], 'library_interactions_settled') if pair['anx'] else None
            rows = [row for row in pair['anx'].get('memory', []) if row.get('label') in
                    ('library_settled', 'library_interactions_settled', 'final')
                    or row.get('label', '').startswith('library_action_')] if pair['anx'] else []
            valid = base and interaction and rows and finite(base.get('rss_bytes')) and all(finite(row.get('rss_bytes')) for row in rows)
            peak = max(row['rss_bytes'] for row in rows) if valid else None
            delta = peak - base['rss_bytes'] if valid else None
            limit = (48 if theme == 'color' else 16) * MIB
            add(f'{theme}_{count}_incremental_rss', valid and delta <= limit,
                baseline_bytes=base.get('rss_bytes') if base else None, peak_anx_bytes=peak,
                delta_bytes=delta, limit_bytes=limit,
                scope='Initial settled library, every 10 interactions, settled after interactions, and final including canceled index')
    execution_passed = bool(results) and all(run.get('passed') is True for run in results)
    budgets_passed = bool(checks) and all(row['passed'] for row in checks)
    return {'pilot_only': pilot, 'suite': suite, 'checks': checks, 'startup': startup,
            'known_native_retention': known_native_retention,
            'q04_qualification': ('Native baseline retention is listed separately; successful checks mean no unexpected retention, '
                                  'not exception-free collection of every old native instance. All memory budgets are unchanged.'),
            'cases_requested': len(expected_cases), 'cases_completed': len(results),
            'suite_complete': complete, 'full_96_case_contract': full_contract,
            'execution_passed': execution_passed, 'budgets_passed': budgets_passed,
            'final_gate_eligible': complete and full_contract and exclusive_confirmed
                                   and execution_passed and budgets_passed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--suite', choices=('pilot', 'full', 'startup', 'library', 'reader', 'stability'), default='pilot')
    parser.add_argument('--themes', nargs='+', choices=('color', 'gray'), default=['color', 'gray'])
    parser.add_argument('--only-case', nargs='+', action='extend', metavar='NAME',
                        help='Run only these exact generated case names; diagnostic suites only, never full')
    parser.add_argument('--diagnostic-hot-memory', action='store_true',
                        help='Log raw Lua/smaps/mallinfo2 before and after each hot home open, without extra GC; forbidden in full')
    parser.add_argument('--exclusive-confirmed', action='store_true',
                        help='Coordinator confirms other builds, tests and emulators have stopped; required beyond pilot')
    args = parser.parse_args()
    if len(set(args.themes)) != len(args.themes):
        parser.error('themes must not contain duplicates')
    if args.suite == 'full' and set(args.themes) != {'color', 'gray'}:
        parser.error('full requires both color and gray: exactly 96 cases')
    if args.suite == 'full' and args.only_case:
        parser.error('--only-case is not allowed with full; use a diagnostic suite')
    if args.suite == 'full' and args.diagnostic_hot_memory:
        parser.error('--diagnostic-hot-memory is not allowed with full')
    if args.suite != 'pilot' and not args.exclusive_confirmed:
        parser.error('final measurements require --exclusive-confirmed after coordinating an idle test environment')
    cases = case_plan(args.suite, args.themes)
    if args.only_case:
        available = {case['name'] for case in cases}
        missing = sorted(set(args.only_case) - available)
        if missing:
            parser.error('--only-case names not present in the generated matrix: ' + ', '.join(missing))
        selected = set(args.only_case)
        cases = [case for case in cases if case['name'] in selected]
    if args.diagnostic_hot_memory and not any(case['action'] == 'library' and case['mode'] == 'anx' for case in cases):
        parser.error('--diagnostic-hot-memory requires an Anx library case')
    args.runtime, args.evidence = args.runtime.resolve(), args.evidence.resolve()
    for path in (args.runtime, args.evidence):
        if not path.is_relative_to(WORK) or path.exists():
            parser.error('use fresh paths inside /data/koreader-anx-work: ' + str(path))
    args.runtime.mkdir(parents=True); args.evidence.mkdir(parents=True)
    source = source_files()
    for relative in source:
        dest = args.evidence / 'source' / relative; dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / relative, dest)
    identity = {'core_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
                'submodules': subprocess.check_output(['git', 'submodule', 'status', '--recursive'], cwd=REPO, text=True).splitlines(),
                'source_files': source, 'started_at': datetime.now(timezone.utc).isoformat(),
                'platform': platform.platform(), 'cpu_count': os.cpu_count(), 'load_average': os.getloadavg(),
                'cpu_info': [line for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')][:1],
                'memory_info': [line for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith(('MemTotal:', 'MemAvailable:'))],
                'display': {'width': 540, 'height': 720, 'dpi': 160, 'renderer': 'SDL software / Xvfb'},
                'power_mode': 'virtual Linux host; physical battery/performance mode unavailable',
                'suite': args.suite, 'only_cases': args.only_case,
                'diagnostic_hot_memory': args.diagnostic_hot_memory,
                'diagnostic_hot_memory_boundary': 'Optional raw reads immediately before/after hot home; no added GC; diagnostic overhead is outside action timers and must not be used as formal evidence.',
                'cache': 'fresh KO_HOME, shared OS page cache; not disk-cold',
                'plugin_source': 'Test-only discovery points anxui at the immutable source snapshot; native loader and plugin methods execute unchanged.',
                'exclusive_coordinator_confirmation': args.exclusive_confirmed,
                'workload_observation': 'Known compiler/Java/emulator/SDL process names checked before and each second during every case. During a run only its own process group/session is excluded and recorded; before launch no process is excluded. This does not prove host-wide absence of all workloads.',
                'measurement_overhead': 'Latency samples and memory rows stream to JSONL outside timed intervals; Lua does not retain growing result arrays.'}
    write_json(args.evidence / 'identity.json', identity)
    (args.evidence / 'source.diff').write_bytes(subprocess.check_output(['git', 'diff', '--binary'], cwd=REPO))
    manifest = json.loads((WORK / 'fixtures/formats-v1/manifest.json').read_text())
    results = []
    for case in cases:
        try:
            result = run_case(args, case, source, manifest)
        except Exception as error:
            write_json(args.evidence / 'harness-error.json', {'case': case, 'error': str(error), 'completed': len(results)})
            raise
        results.append(result)
        write_json(args.evidence / 'summary.json', analyze(results, args.suite, cases,
                   completed=False, exclusive_confirmed=args.exclusive_confirmed))
        if not result['passed']:
            break
    summary = analyze(results, args.suite, cases, completed=True, exclusive_confirmed=args.exclusive_confirmed)
    summary.update(cases_requested=len(cases), cases_completed=len(results),
                   cases=[{'name': r['case']['name'], 'passed': r['passed'], 'result': r['evidence'] + '/result.json'} for r in results])
    if args.diagnostic_hot_memory:
        summary['diagnostic_hot_memory'] = True
        summary['final_gate_eligible'] = False
    write_json(args.evidence / 'summary.json', summary)
    print(json.dumps({'summary': str(args.evidence / 'summary.json'), 'cases_completed': len(results),
                      'execution_passed': summary['execution_passed'], 'budgets_passed': summary['budgets_passed'],
                      'final_gate_eligible': summary['final_gate_eligible']}, ensure_ascii=False), flush=True)
    raise SystemExit(0 if len(results) == len(cases) and summary['execution_passed'] and summary['budgets_passed'] else 1)


if __name__ == '__main__':
    main()
