#!/usr/bin/env python3
"""Run the real KOReader SDL app with copied books and an isolated test-only patch."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import math
import subprocess
import sys
import time
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--book", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--scenario", choices=("baseline", "classic_home", "home", "components", "entry_points", "shelf_import", "library", "large_library", "replace", "resize", "startup", "reader_tools", "note_index", "format", "advanced", "statistics", "settings_groups", "assistant", "plugins", "visual", "broken", "broken_classic", "file_actions", "roundtrip", "init_failure", "settings", "home_failure"), default="baseline")
    parser.add_argument("--assistant-case", choices=("absent", "installed"), default="absent")
    parser.add_argument("--library-count", type=int, choices=(1000, 5000), default=5000)
    startup_cases = ("library", "classic", "last", "history", "favorites", "folder_shortcuts", "guide", "explicit_file", "explicit_dir", "recovery", "disabled", "missing_last")
    parser.add_argument("--startup-case", choices=(*startup_cases, "all"), default="library")
    parser.add_argument("--samples", type=int, default=1, help="fresh-process/configuration samples, run sequentially")
    parser.add_argument("--width", type=int, default=540)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--language", choices=("en_US", "zh_CN"), default="en_US")
    parser.add_argument("--theme", choices=("auto", "color", "gray"), default="color")
    parser.add_argument("--large-text", action="store_true")
    args = parser.parse_args()
    args.book = args.book.resolve()
    args.runtime = args.runtime.resolve()
    args.evidence = args.evidence.resolve()
    repo = Path(__file__).resolve().parents[3]
    work = Path("/data/koreader-anx-work").resolve()
    for path in (args.runtime, args.evidence):
        if not path.resolve().is_relative_to(work):
            parser.error("runtime and evidence must be inside /data/koreader-anx-work")
    if not args.book.is_file() or args.book.suffix.lower() not in (".epub", ".pdf", ".djvu", ".djv", ".cbz", ".cbt", ".txt", ".fb2", ".mobi", ".azw3"):
        parser.error("book must be an existing supported reading test fixture")
    if args.runtime.exists():
        parser.error("use a fresh runtime directory; existing settings must not be overwritten")
    if args.evidence.exists() and any(args.evidence.iterdir()):
        parser.error("use a fresh evidence directory; previous results must not be overwritten")
    if not 1 <= args.samples <= 100:
        parser.error("samples must be between 1 and 100")
    if args.scenario == "startup" and args.startup_case == "all":
        args.runtime.mkdir(parents=True)
        args.evidence.mkdir(parents=True, exist_ok=True)
        outcomes = []
        for case in startup_cases:
            invocation = [sys.executable, str(Path(__file__).resolve()), "--book", str(args.book),
                          "--runtime", str(args.runtime / case), "--evidence", str(args.evidence / case),
                          "--scenario", "startup", "--startup-case", case, "--language", args.language]
            with (args.evidence / f"{case}.log").open("w") as log:
                code = subprocess.call(invocation, stdout=log, stderr=subprocess.STDOUT)
            result_file = args.evidence / case / "result.json"
            result = json.loads(result_file.read_text()) if result_file.exists() else {"passed": False}
            outcomes.append({"case": case, "exit_code": code, "passed": result["passed"], "result": str(result_file)})
            print(f"{case}: {'PASS' if code == 0 and result['passed'] else 'FAIL'}", flush=True)
        summary = {"cases": outcomes, "passed": all(r["passed"] and not r["exit_code"] for r in outcomes)}
        (args.evidence / "matrix.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        raise SystemExit(0 if summary["passed"] else 1)
    if args.samples > 1:
        args.runtime.mkdir(parents=True)
        args.evidence.mkdir(parents=True, exist_ok=True)
        results = []
        for index in range(1, args.samples + 1):
            run = f"sample-{index:02d}"
            invocation = [sys.executable, str(Path(__file__).resolve()), "--book", str(args.book),
                          "--runtime", str(args.runtime / run), "--evidence", str(args.evidence / run),
                          "--scenario", args.scenario, "--width", str(args.width), "--height", str(args.height)]
            invocation += ["--language", args.language, "--theme", args.theme]
            invocation += ["--startup-case", args.startup_case]
            if args.large_text:
                invocation += ["--large-text"]
            with (args.evidence / f"{run}.log").open("w") as log:
                code = subprocess.call(invocation, stdout=log, stderr=subprocess.STDOUT)
            result_file = args.evidence / run / "result.json"
            result = json.loads(result_file.read_text()) if result_file.exists() else {"passed": False}
            results.append({"result": str(result_file), "exit_code": code, "passed": result["passed"]})
            print(f"{run}: {'PASS' if code == 0 and result['passed'] else 'FAIL'}", flush=True)
            if code or not result["passed"]:
                break
        values = []
        for entry in results:
            if entry["passed"]:
                sample = json.loads(Path(entry["result"]).read_text())
                values.append(sample["runs"][0]["startup"]["launch_to_main_paint_ms"])
        ordered = sorted(values)
        summary = {"scenario": args.scenario, "samples_requested": args.samples, "results": results,
                   "launch_to_main_paint_ms": values, "cache": "fresh KO_HOME per sample; shared OS page cache",
                   "p50_ms": ordered[math.ceil(len(ordered) * .5) - 1] if ordered else None,
                   "p95_ms": ordered[math.ceil(len(ordered) * .95) - 1] if ordered else None,
                   "passed": len(results) == args.samples and all(e["passed"] and not e["exit_code"] for e in results)}
        (args.evidence / "samples.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        raise SystemExit(0 if summary["passed"] else 1)
    args.runtime.mkdir(parents=True)
    args.evidence.mkdir(parents=True, exist_ok=True)
    books = args.runtime / "books"
    books.mkdir()
    book = books / args.book.name
    shutil.copy2(args.book, book)
    (books / "empty").mkdir()
    if args.scenario == "shelf_import":
        import re
        scan = books / "scan"
        scan.mkdir()
        titles = ["海边的清晨", "山野来信", "城市漫步", "读书与生活", "时间的形状", "星空笔记", "旅行手记"]
        for index, title in enumerate(titles, 1):
            with zipfile.ZipFile(book) as original, zipfile.ZipFile(scan / f"{index:02d}-{title}.epub", "w") as clone:
                for info in original.infolist():
                    data = original.read(info.filename)
                    if info.filename.endswith(".opf"):
                        data = re.sub(r"<dc:title>.*?</dc:title>", "<dc:title>" + title + "</dc:title>", data.decode()).encode()
                    clone.writestr(info, data)
        (scan / "cover.jpg").write_bytes(b"not an ebook")
        (scan / ".hidden").mkdir()
        shutil.copy2(book, scan / ".hidden" / "ignored.epub")
        (scan / "ignored.sdr").mkdir()
        shutil.copy2(book, scan / "ignored.sdr" / "ignored.epub")
        os.symlink(scan, scan / "cycle")
    archive = args.runtime / "fixture-archive.zip"
    if args.scenario == "plugins":
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("fixture.txt", "Self-authored archive entry for local plugin verification.")
    if args.scenario in ("library", "note_index"):
        (books / "other").mkdir()
        shutil.copy2(args.book, books / "other" / args.book.name)
    if args.scenario == "large_library":
        for index in range(2, args.library_count + 1):
            os.link(book, books / f"Sample-{index:05d}{book.suffix}")
    replacement = args.runtime / "replacement.epub"
    if args.scenario == "replace":
        if book.suffix.lower() != ".epub":
            parser.error("replace scenario requires the generated EPUB fixture")
        import re
        with zipfile.ZipFile(book) as source, zipfile.ZipFile(replacement, "w") as target:
            for entry in source.infolist():
                data = source.read(entry.filename)
                if entry.filename.endswith(".opf"):
                    data = re.sub(b'<dc:title>.*?</dc:title>', b'<dc:title>Replacement edition with a new title</dc:title>', data)
                    data = re.sub(b'<dc:creator>.*?</dc:creator>', b'<dc:creator>Replacement Author</dc:creator>', data)
                target.writestr(entry, data)
    patches = args.runtime / "patches"
    patches.mkdir()
    patch = Path(__file__).with_name("baseline-smoke.lua" if args.scenario == "baseline" else "home-smoke.lua")
    shutil.copy2(patch, patches / "2-anx-baseline-test.lua")
    metrics_patch = Path(__file__).with_name("startup-metrics.lua")
    shutil.copy2(metrics_patch, patches / "2-anx-00-metrics.lua")
    if args.scenario == "advanced":
        import struct
        dictionary = args.runtime / "data/dict/anx-fixture"
        dictionary.mkdir(parents=True)
        definition = b"A self-authored test definition for the searchable marker in this book."
        index = b"needle\0" + struct.pack(">II", 0, len(definition))
        (dictionary / "fixture.dict").write_bytes(definition)
        (dictionary / "fixture.idx").write_bytes(index)
        (dictionary / "fixture.ifo").write_text("StarDict's dict ifo file\nversion=2.4.2\nbookname=Anx fixture dictionary\nwordcount=1\nidxfilesize=" + str(len(index)) + "\nsametypesequence=m\n")
    settings = {
        "plugins_disabled": {"anxui": args.scenario in ("baseline", "classic_home", "broken_classic") or (args.scenario == "startup" and args.startup_case == "disabled")},
        "extra_plugin_paths": [],
        "color_rendering": True,
        "language": args.language,
        "anxui": {"mode": args.theme, "large_text": args.large_text},
        "home_dir": str(books),
        "lastdir": str(books),
    }
    if args.scenario == "assistant" and args.assistant_case == "installed":
        vendor = work / "vendor/koassistant.koplugin"
        pin = "b89a60daf52bc9c3b33419607f48bbecde302461"
        assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=vendor, text=True).strip() == pin
        extra = args.runtime / "extra-plugins"
        copied = extra / "koassistant.koplugin"
        shutil.copytree(vendor, copied, ignore=shutil.ignore_patterns(".git"))
        (copied / "configuration.lua").write_text('return { provider = "anthropic", features = { auto_check_updates = false, debug = false } }\n')
        settings["extra_plugin_paths"] = [str(extra)]
    startup_settings = ""
    if args.scenario == "startup":
        mode = args.startup_case if args.startup_case in ("last", "history", "favorites", "folder_shortcuts") else "filemanager"
        if args.startup_case == "missing_last":
            mode = "last"
        startup_settings = ', start_with = ' + json.dumps(mode) + ', lastfile = ' + json.dumps(str(book) + ('.missing' if args.startup_case == 'missing_last' else ''), ensure_ascii=False)
        if args.startup_case != "guide":
            startup_settings += ', quickstart_shown_version = 9999999999'
        settings["startup_case"] = args.startup_case
    # Explicit Lua, rather than treating a JSON object as Lua source.
    (args.runtime / "settings.reader.lua").write_text(
        'return { plugins_disabled = { anxui = '
        + ("true" if settings["plugins_disabled"]["anxui"] else "false")
        + ' }, extra_plugin_paths = {' + ', '.join(json.dumps(p) for p in settings["extra_plugin_paths"]) + '}, '
        'color_rendering = true, language = ' + json.dumps(args.language)
        + ', anxui = { mode = ' + json.dumps(args.theme) + ', large_text = '
        + ("true" if args.large_text else "false")
        + ', startup = ' + ('true' if args.scenario == 'startup' and args.startup_case != 'classic' else 'false')
        + ', opening = ' + ('true' if args.scenario == 'startup' and args.startup_case == 'recovery' else 'false')
        + ' }' + startup_settings + ', home_dir = '
        + json.dumps(str(books), ensure_ascii=False)
        + ", lastdir = " + json.dumps(str(books), ensure_ascii=False) + " }\n"
    )
    command = ["./kodev", "run", "-b", "-W", str(args.width), "-H", str(args.height), "-D", "160"]
    env = os.environ.copy()
    env.update(KO_HOME=str(args.runtime), ANX_SMOKE_EVIDENCE=str(args.evidence),
               SDL_RENDER_DRIVER="software", SDL_VIDEO_DRIVER="x11", PARALLEL_JOBS="1",
               ANX_SMOKE_BOOK=str(book), ANX_SMOKE_EXPECTED=str(args.evidence / "expected-data.json"))
    env["ANX_SMOKE_STARTUP_CASE"] = args.startup_case
    env["ANX_SMOKE_LIBRARY_COUNT"] = str(args.library_count)
    env["ANX_SMOKE_REPLACEMENT"] = str(replacement)
    env["ANX_SMOKE_ASSISTANT_CASE"] = args.assistant_case
    env["ANX_SMOKE_ARCHIVE"] = str(archive)
    started = time.monotonic()
    result = {"cwd": str(repo), "settings": settings, "scenario": args.scenario,
              "backend": "real SDL3 under Xvfb", "width": args.width, "height": args.height,
              "interaction": "original UI actions; components scenario additionally injects real X11 keyboard/mouse events",
              "book": str(book), "fixture_sha256": hashlib.sha256(book.read_bytes()).hexdigest(),
              "core_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
              "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest()}
    source_paths = sorted((repo / "plugins/anxui.koplugin").rglob("*.lua"))
    source_paths += sorted((repo / "spec/unit").glob("anxui*_spec.lua"))
    source_paths += [Path(__file__).resolve(), patch, metrics_patch]
    source_paths += [Path(__file__).with_name(name) for name in ("reader-smoke.lua", "note-index-smoke.lua", "advanced-smoke.lua", "statistics-smoke.lua", "settings-groups-smoke.lua", "assistant-smoke.lua")]
    source_paths += [Path(__file__).with_name(name) for name in ("plugins-smoke.lua", "plugins-manifest.lua")]
    source_paths += [Path(__file__).with_name("visual-smoke.lua")]
    source_paths += [Path(__file__).with_name("entry-smoke.lua"), Path(__file__).with_name("shelf-smoke.lua")]
    result["source_files"] = {
        str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in source_paths
    }
    for path in source_paths:
        destination = args.evidence / "source" / path.relative_to(repo)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
    result["submodules"] = subprocess.check_output(
        ["git", "submodule", "status", "--recursive"], cwd=repo, text=True,
    ).splitlines()
    (args.evidence / "source.diff").write_bytes(subprocess.check_output(
        ["git", "diff", "--binary"], cwd=repo,
    ))
    result["runs"] = []
    if replacement.exists():
        result["replacement_sha256"] = hashlib.sha256(replacement.read_bytes()).hexdigest()
    restart_phases = {"shelf_import": "shelf_reopen", "roundtrip": "reopen", "format": "reopen", "settings": "settings_reopen", "home_failure": "recovery_resume"}
    phases = [args.scenario, restart_phases[args.scenario]] if args.scenario in restart_phases else [args.scenario]
    if args.scenario == "plugins":
        phases = ["plugins", "plugins_disabled", "plugins_enabled"]
    for phase in phases:
        phase_evidence = args.evidence / phase
        phase_evidence.mkdir(exist_ok=True)
        env.update(ANX_SMOKE_SCENARIO=phase, ANX_SMOKE_EVIDENCE=str(phase_evidence))
        target = book if phase in ("baseline", "reopen") else books
        targets = [str(target)]
        if phase == "startup":
            targets = [str(book)] if args.startup_case == "explicit_file" else [str(books)] if args.startup_case == "explicit_dir" else []
        invocation = ["xvfb-run", "-a", "-s", "-screen 0 1440x1000x24 -nolisten tcp", *command, *targets]
        with (phase_evidence / "application.log").open("w") as log:
            env["ANX_SMOKE_LAUNCH_MONOTONIC"] = str(time.monotonic())
            process = subprocess.Popen(invocation, cwd=repo, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline, handled = time.monotonic() + 120, set()
                input_results = []
                while process.poll() is None:
                    if time.monotonic() > deadline:
                        raise subprocess.TimeoutExpired(invocation, 120)
                    request_path = phase_evidence / "input-request.json"
                    if request_path.exists():
                        try:
                            request = json.loads(request_path.read_text())
                        except json.JSONDecodeError:
                            time.sleep(.05)
                            continue
                        if request["id"] not in handled:
                            handled.add(request["id"])
                            input_env = env.copy()
                            input_env["DISPLAY"] = request["display"]
                            if request.get("xauthority"):
                                input_env["XAUTHORITY"] = request["xauthority"]
                            try:
                                window = subprocess.check_output(
                                    ["xdotool", "search", "--name", "KOReader"], env=input_env, text=True,
                                ).splitlines()[-1]
                                subprocess.run(["xdotool", "windowfocus", "--sync", window], env=input_env, check=True)
                                for action in request["actions"]:
                                    if action["kind"] == "key":
                                        command_args = ["key", "--clearmodifiers", action["value"]]
                                    elif action["kind"] == "type":
                                        command_args = ["type", "--clearmodifiers", "--delay", "30", action["value"]]
                                    elif action["kind"] == "click":
                                        command_args = ["mousemove", "--window", window, str(action["x"]), str(action["y"]), "click", "1"]
                                    elif action["kind"] == "swipe":
                                        command_args = ["mousemove", "--window", window, str(action["x"]), str(action["y"]), "mousedown", "1"]
                                        for fraction in (.25, .5, .75, 1):
                                            x = round(action["x"] + fraction * (action["end_x"] - action["x"]))
                                            y = round(action["y"] + fraction * (action["end_y"] - action["y"]))
                                            command_args += ["sleep", "0.04", "mousemove", "--window", window, str(x), str(y)]
                                        command_args += ["mouseup", "1"]
                                    elif action["kind"] == "resize":
                                        command_args = ["windowsize", "--sync", window, str(action["width"]), str(action["height"])]
                                    else:
                                        raise ValueError("unsupported test input")
                                    subprocess.run(["xdotool", *command_args], env=input_env, check=True, timeout=10)
                                answer = {"id": request["id"], "ok": True}
                            except (subprocess.SubprocessError, ValueError, IndexError) as error:
                                answer = {"id": request["id"], "ok": False, "error": str(error)}
                            input_results.append({"request": request, "result": answer})
                            (phase_evidence / "input-results.json").write_text(json.dumps(input_results, indent=2))
                            temporary = phase_evidence / "input-response.tmp"
                            temporary.write_text(json.dumps(answer))
                            temporary.rename(phase_evidence / "input-response.json")
                    time.sleep(.05)
                code = process.wait()
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 124
        contents = (phase_evidence / "application.log").read_text()
        passed = code == 0 and "ANX_SMOKE_PASS" in contents
        metrics_file = phase_evidence / "startup.json"
        result["runs"].append({"phase": phase, "command": invocation, "exit_code": code,
                               "passed": passed, "log": str(phase_evidence / "application.log"),
                               "startup": json.loads(metrics_file.read_text()) if metrics_file.exists() else None})
        if not passed:
            break
    result["elapsed_seconds"] = time.monotonic() - started
    result["passed"] = len(result["runs"]) == len(phases) and all(run["passed"] for run in result["runs"])
    result["screenshots"] = [str(p) for p in sorted(args.evidence.rglob("*.png"))]
    (args.evidence / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
