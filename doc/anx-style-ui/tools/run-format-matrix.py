#!/usr/bin/env python3
"""Run paired classic/Anx format checks using isolated SDL processes."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=2, choices=(1, 2, 3))
    args = parser.parse_args()
    if args.runtime.exists() or args.evidence.exists(): parser.error('use fresh runtime and evidence roots')
    args.runtime.mkdir(parents=True); args.evidence.mkdir(parents=True)
    runner = Path(__file__).with_name('run-sdl-smoke.py')
    records = json.loads((args.fixtures / 'manifest.json').read_text())

    def check(record):
        book = Path(record['path']); key = book.stem + '-' + book.suffix[1:]
        result = {'fixture': record, 'runs': []}
        phases = ('broken_classic', 'broken') if 'broken' in book.name else ('baseline', 'format')
        if record['id'] in ('S01', 'S02'): phases += ('advanced',)
        for phase in phases:
            evidence = args.evidence / key / phase
            command = [sys.executable, str(runner), '--book', str(book), '--runtime', str(args.runtime / key / phase),
                       '--evidence', str(evidence), '--scenario', phase, '--language', 'zh_CN']
            log = args.evidence / (key + '-' + phase + '.console.log')
            with log.open('w') as output:
                process = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
            path = evidence / 'result.json'
            details = json.loads(path.read_text()) if path.exists() else {}
            run = {'phase': phase, 'exit_code': process.returncode, 'passed': details.get('passed', False),
                   'result': str(path), 'console': str(log), 'command': command}
            result['runs'].append(run)
            print(json.dumps({'fixture': key, **run}, ensure_ascii=False), flush=True)
            if phase == phases[0] and not run['passed']:
                result['note'] = 'Original baseline failed; no compatibility claim and no dependent Anx run.'
                break
        result['passed'] = len(result['runs']) == len(phases) and all(run['passed'] for run in result['runs'])
        return result

    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        results = list(executor.map(check, records))
    summary = {'passed': all(result['passed'] for result in results), 'fixtures': results}
    (args.evidence / 'matrix.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': summary['passed'], 'fixtures': len(results), 'summary': str(args.evidence / 'matrix.json')}))
    return 0 if summary['passed'] else 1


if __name__ == '__main__': sys.exit(main())
