#!/usr/bin/env python3
"""Exercise install_cli in a temporary directory; never touch /usr/bin or UFW."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ghost-origin.sh').read_text()
function = source.split('install_cli() (', 1)[1].split('\n)\n', 1)[0]
with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    target = folder / 'ghost-origin'
    function = 'install_cli() (' + function.replace('/usr/bin/', tmp + '/') + '\n)\n'
    prelude = 'set -euo pipefail\nDRY_RUN=0\nlog() { :; }; warn() { :; }; die() { echo "$*" >&2; exit 1; }\nchown() { :; }\n'
    runner = folder / 'runner.sh'
    runner.write_text(prelude + function + 'install_cli\n# main "$@"\n')
    # Marker checked by install_cli must be present, but need not execute.
    runner.write_text(runner.read_text().replace('# main "$@"', 'main() { :; }\nmain "$@"'))
    subprocess.run(['bash', str(runner)], check=True)
    assert target.read_bytes() == runner.read_bytes()
    assert target.stat().st_mode & 0o777 == 0o755
    subprocess.run(['bash', str(target)], check=True)  # self-replacement
    original = target.read_bytes()
    subprocess.run(['bash', '-c', prelude.replace('DRY_RUN=0', 'DRY_RUN=1') + function + 'install_cli'], check=True)
    assert target.read_bytes() == original
    # bash -c has no BASH_SOURCE file. Mock only the download and ownership.
    payload = folder / 'payload.sh'
    payload.write_text('#!/bin/bash\nmain() { :; }\nmain "$@"\n')
    download = 'curl() { cp -- "$PAYLOAD" "${@: -1}"; }\n'
    env = dict(os.environ, PAYLOAD=str(payload))
    subprocess.run(['bash', '-c', prelude + download + function + 'install_cli'], env=env, check=True)
    assert target.read_bytes() == payload.read_bytes()
    # Explicit update must download even when invoked from a local installed file.
    runner.write_text(prelude + download + function + 'install_cli remote\n')
    subprocess.run(['bash', str(runner)], env=env, check=True)
    assert target.read_bytes() == payload.read_bytes()
    runner.write_text(prelude.replace('DRY_RUN=0', 'DRY_RUN=1') + 'curl() { exit 99; }\n' + function + 'install_cli remote\n')
    subprocess.run(['bash', str(runner)], check=True)
    assert target.read_bytes() == payload.read_bytes()
    for mock in ['curl() { return 22; }', 'curl() { printf "" > "${@: -1}"; }',
                 'curl() { printf "if broken" > "${@: -1}"; }']:
        result = subprocess.run(['bash', '-c', prelude + mock + '\n' + function + 'install_cli'], capture_output=True)
        assert result.returncode != 0
        assert target.read_bytes() == payload.read_bytes()
        assert not list(folder.glob('.ghost-origin.*'))
for flag in ['--version', 'version', '-v']:
    output = subprocess.check_output(['bash', str(ROOT / 'ghost-origin.sh'), flag], text=True)
    assert '1.2.1' in output and '2026-09-17' in output
subprocess.run(['bash', str(ROOT / 'ghost-origin.sh'), 'update', '--dry-run'], check=True)
for filename in ['README.md', 'README.en.md']:
    text = (ROOT / filename).read_text()
    assert 'sudo ./ghost-origin.sh ' not in text
    assert 'ghost-origin update' in text
print('PASS: CLI install/update, version, docs, failure preservation and cleanup')
