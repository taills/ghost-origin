#!/usr/bin/env python3
"""Test real key validation with a mocked fwknop CLI; no host configuration changes."""
import base64
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ghost-origin.sh').read_text().rsplit('\nmain "$@"', 1)[0]
with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    lib = folder / 'lib.sh'
    lib.write_text(source.replace('/etc/fwknop/', tmp + '/'))
    keys = folder / 'ghost-origin.keys'
    valid = 'KEY_BASE64 ' + base64.b64encode(b'k' * 32).decode() + '\nHMAC_KEY_BASE64 ' + base64.b64encode(b'h' * 64).decode() + '\n'
    payload = folder / 'payload'
    payload.write_text(valid)
    mock = '''
backup_file() { :; }
fwknop() {
  local output=""
  while (( $# )); do
    case "$1" in
      --key-len) [[ "$2" == 32 ]] || return 68; shift 2 ;;
      --hmac-key-len) [[ "$2" == 64 ]] || return 68; shift 2 ;;
      --key-gen-file) output="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ "${FAIL:-0}" == 0 ]] || return 68
  cp "$PAYLOAD" "$output"
}
'''
    def run(cmd, fail='0'):
        return subprocess.run(['bash', '-c', 'source "$1"\n' + mock + cmd, 'test', str(lib)],
                              env=dict(os.environ, PAYLOAD=str(payload), FAIL=fail), capture_output=True, text=True)
    assert run('generate_keys').returncode == 0
    assert keys.read_text() == valid and keys.stat().st_mode & 0o777 == 0o600
    assert run('generate_keys', '1').returncode == 0  # reuse without invoking fwknop
    assert run('FORCE_KEYS=1; generate_keys', '1').returncode != 0
    assert keys.read_text() == valid
    payload.write_text('KEY_BASE64 invalid\n')
    assert run('FORCE_KEYS=1; generate_keys').returncode != 0
    assert keys.read_text() == valid
    keys.write_text('')
    assert run('generate_keys').returncode != 0
    payload.write_text(valid)
    assert run('FORCE_KEYS=1; generate_keys').returncode == 0
    payload.write_text(valid.replace('KEY_BASE64 ', 'KEY_BASE64: '))
    assert run('FORCE_KEYS=1; generate_keys').returncode == 0
    assert not list(folder.glob('.ghost-origin-keys.*'))
print('PASS: key lengths, validation, reuse, permissions, failure preservation, forced recovery and cleanup')
