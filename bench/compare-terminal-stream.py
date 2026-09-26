"""Compare serial process timings on pre-generated terminal-stream corpora.

Inputs must already exist; generation and profiling must run separately.
Timings include process startup, file IO and terminal state updates, not GPU
rendering or ConPTY. Each executable receives one warmup then repeated trials.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=5)
    parser.add_argument('--corpora', default='ascii,unicode,cjk,greek,emoji,combining')
    parser.add_argument('executables', nargs='+', type=Path)
    opts = parser.parse_args()
    result = dict(method=__doc__, rows=29, columns=85, chunk_size=131072, corpora={}, trials=[])
    for kind in opts.corpora.split(','):
        path = opts.data_dir / (kind + '.txt')
        result['corpora'][kind] = dict(bytes=path.stat().st_size, sha256=digest(path))
        for executable in opts.executables:
            command = [str(executable.resolve()), '+terminal-stream', '--terminal-rows=29',
                       '--terminal-cols=85', '--chunk-size=131072', '--data=' + str(path.resolve())]
            samples = []
            for i in range(opts.repetitions + 1):
                start = time.perf_counter()
                completed = subprocess.run(command, capture_output=True, timeout=120,
                                           creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                elapsed = (time.perf_counter() - start) * 1000
                if completed.returncode:
                    raise RuntimeError(completed.stderr.decode(errors='replace'))
                if i:
                    samples.append(elapsed)
            row = dict(corpus=kind, executable=str(executable), sha256=digest(executable),
                       samples_ms=samples, median_ms=statistics.median(samples))
            result['trials'].append(row)
            print(f'{kind}: {executable.name}: {row["median_ms"]:.2f} ms', flush=True)
            opts.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
