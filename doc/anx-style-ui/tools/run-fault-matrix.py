#!/usr/bin/env python3
"""Exercise real crashes/recovery with a private install and authoritative test data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
work = Path('/data/koreader-anx-work')
for path in (args.runtime, args.evidence):
    if not path.resolve().is_relative_to(work) or path.exists():
        parser.error('use fresh runtime/evidence paths inside /data/koreader-anx-work')
    path.mkdir(parents=True)
install = args.runtime / 'install'
install.mkdir()
original_install = repo / 'koreader-emulator-x86_64-linux-gnu-debug/koreader'
for child in original_install.iterdir():
    if child.name != 'plugins':
        (install / child.name).symlink_to(child.resolve(), target_is_directory=child.is_dir())
(install / 'plugins').mkdir()
for child in (original_install / 'plugins').iterdir():
    target = install / 'plugins' / child.name
    if child.name == 'anxui.koplugin': shutil.copytree(child.resolve(), target)
    else: target.symlink_to(child.resolve(), target_is_directory=child.is_dir())
plugin = install / 'plugins/anxui.koplugin'
source = {str(p.relative_to(plugin)): hashlib.sha256(p.read_bytes()).hexdigest() for p in plugin.rglob('*.lua')}
shutil.copytree(plugin, args.evidence / 'source/plugin')
shutil.copy2(__file__, args.evidence / Path(__file__).name)
shutil.copy2(Path(__file__).with_name('fault-smoke.lua'), args.evidence / 'fault-smoke.lua')
home = args.runtime / 'config'
(home / 'patches').mkdir(parents=True)
shutil.copy2(Path(__file__).with_name('fault-smoke.lua'), home / 'patches/2-anx-fault.lua')
books = args.runtime / 'books'; books.mkdir()
book = books / 'recovery.epub'
shutil.copy2(work / 'fixtures/g0-v1/S01-中文阅读测试.epub', book)
settings = home / 'settings.reader.lua'
settings.write_text('return {plugins_disabled={}, extra_plugin_paths={}, language="zh_CN", home_dir=' + json.dumps(str(books))
                    + ', lastdir=' + json.dumps(str(books)) + ', quickstart_shown_version=9999999999, anxui={startup=false}}\n')
expected = args.evidence / 'expected-data.json'
env = os.environ.copy()
env.update(KO_HOME=str(home), SDL_RENDER_DRIVER='software', SDL_VIDEO_DRIVER='x11',
           EMULATE_READER_W='540', EMULATE_READER_H='720', EMULATE_READER_DPI='160',
           ANX_FAULT_BOOK=str(book), ANX_FAULT_EXPECTED=str(expected), ANX_FAULT_SETTINGS=str(settings))
results = []

def update_settings(lua):
    code = 'dofile("setupkoenv.lua"); local s=require("luasettings"):open(os.getenv("ANX_FAULT_SETTINGS")); ' + lua + '; s:flush()'
    subprocess.run([str(install / 'luajit'), '-e', code], cwd=install, env=env, check=True)

def stat_rows():
    path = home / 'settings/statistics.sqlite3'
    if not path.exists(): return None
    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as db:
        return db.execute('SELECT id_book,page,start_time,duration FROM page_stat_data ORDER BY id_book,page,start_time').fetchall()

def run(phase):
    dest = args.evidence / phase; dest.mkdir()
    env.update(ANX_FAULT_PHASE=phase, ANX_FAULT_EVIDENCE=str(dest))
    command = ['xvfb-run', '-a', '-s', '-screen 0 1440x1000x24 -nolisten tcp', './luajit', 'reader.lua', str(book if phase == 'seed' else books)]
    before = stat_rows()
    killed = False
    with (dest / 'application.log').open('w') as log:
        proc = subprocess.Popen(command, cwd=install, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 90
        while proc.poll() is None and time.monotonic() < deadline:
            if phase == 'crash' and (dest / 'kill-ready.json').exists():
                os.killpg(proc.pid, signal.SIGKILL); killed = True; break
            time.sleep(.05)
        if proc.poll() is None and not killed: os.killpg(proc.pid, signal.SIGTERM)
        try: code = proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL); code = proc.wait()
    contents = (dest / 'application.log').read_text()
    passed = killed if phase == 'crash' else code == 0 and 'ANX_FAULT_PASS' in contents
    after = stat_rows()
    # Original records must remain. Native reading may append a newly completed interval.
    preserved = before is None or all(row in after for row in before)
    passed = passed and preserved
    if passed and phase == 'seed':
        shutil.copytree(books, args.evidence / 'seed-books')
        shutil.copytree(home / 'settings', args.evidence / 'seed-settings')
    entry = {'phase':phase, 'passed':passed, 'exit_code':code, 'controlled_group_kill':killed,
             'original_stat_rows_preserved':preserved, 'stat_rows_before':before, 'stat_rows_after':after,
             'command':command, 'log':str(dest / 'application.log')}
    results.append(entry)
    (args.evidence / 'result.json').write_text(json.dumps({'core_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),
        'source_files':source, 'runs':results, 'passed':all(x['passed'] for x in results),
        'scope':'controlled test-process kill; not every possible native crash; all files isolated'}, ensure_ascii=False, indent=2)+'\n')
    print(phase, 'PASS' if passed else 'FAIL', flush=True)
    if not passed: raise SystemExit(1)

run('seed')
run('crash')
update_settings('s:saveSetting("plugins_disabled", {anxui=true})')
run('disabled')
update_settings('s:saveSetting("plugins_disabled", {})')
removed = install / 'anxui-disabled'
plugin.rename(removed)
run('removed')
removed.rename(plugin)
main = plugin / 'main.lua'; original = main.read_bytes()
main.write_text('ANX CORRUPT LUA SOURCE FOR ISOLATED RECOVERY TEST')
run('corrupt_main')
main.write_bytes(original.replace(b'function AnxUI:init()', b'function AnxUI:init()\n    error("ANX_FAULT_INJECTED_INIT")', 1))
run('failed_init')
main.write_bytes(original)
for phase, value in [('future_schema','{schema=99, startup=true, extension="future value"}'),
                     ('invalid_settings','"invalid own settings"'),
                     ('opening_marker','{schema=1, startup=true, opening=true}'),
                     ('legacy_settings','{mode="gray", large_text=true, extension="keep legacy extension"}')]:
    update_settings('s:saveSetting("anxui", '+value+')')
    run(phase)
run('disable_live')
run('disabled_after_live')
