#!/usr/bin/env python3
"""Mock package/service probes and mutations; no host firewall/package changes."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ghost-origin.sh').read_text().rsplit('\nmain "$@"', 1)[0]
with tempfile.TemporaryDirectory() as tmp:
    lib = Path(tmp) / 'lib.sh'
    lib.write_text(source)
    mocks = r'''
package_installed() { [[ ",${PACKAGES:-}," == *",$1,"* ]]; }
have_cmd() {
  case "$1" in
    knockd|fwknop|fwknopd) [[ ",${BINARIES:-}," == *",$1,"* ]] ;;
    *) return 0 ;;
  esac
}
service_present() { [[ ",${SERVICES:-}," == *",$1,"* ]]; }
confirm_existing_tool() {
  printf 'PROMPT %s\n' "$1"
  [[ "$1" == *knockd* ]] && [[ "${NO_KNOCK:-0}" == 1 ]] && return 1
  [[ "$1" == *fwknop* ]] && [[ "${NO_FW:-0}" == 1 ]] && return 1
  return 0
}
run() { printf 'MUTATE'; printf ' %s' "$@"; printf '\n'; }
backup_file() { printf 'BACKUP %s\n' "$1"; }
detect_fwknop_unit() { :; }
SKIP_APT=${TEST_SKIP:-0}
preflight_existing_tools
install_packages
'''
    def check(env, ok=True):
        result = subprocess.run(['bash', '-c', 'source "$1"\n' + mocks, 'test', str(lib)],
                                env=dict(os.environ, **env), text=True, capture_output=True)
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        if not ok:
            assert 'MUTATE' not in result.stdout and 'BACKUP' not in result.stdout
        return result.stdout

    out = check({})
    assert 'PROMPT' not in out and '--only-upgrade' not in out and 'remove -y' not in out
    out = check({'PACKAGES': 'knockd,fwknop-server,fwknop-client', 'SERVICES': 'knockd.service'})
    assert out.count('PROMPT') == 2
    assert out.index('PROMPT 检测到 fwknop') < out.index('MUTATE')
    assert 'apt-get remove -y knockd' in out and 'purge' not in out
    assert 'systemctl disable --now knockd.service' in out
    assert 'apt-get install -y --only-upgrade fwknop-server fwknop-client' in out
    assert out.index('BACKUP /etc/fwknop/access.conf') < out.index('--only-upgrade')
    assert out.index('BACKUP /etc/knockd.conf') < out.index('remove -y knockd')
    check({'PACKAGES': 'knockd', 'NO_KNOCK': '1'}, False)
    check({'PACKAGES': 'knockd,fwknop-server', 'NO_FW': '1'}, False)
    check({'PACKAGES': 'fwknop-client', 'NO_FW': '1'}, False)
    check({'BINARIES': 'knockd'}, False)
    check({'SERVICES': 'fwknopd.service'}, False)
    check({'PACKAGES': 'fwknop-client', 'TEST_SKIP': '1'}, False)
    # Real confirmation helper: --yes is not an early-return bypass.
    helper = source.split('confirm_existing_tool() {', 1)[1].split('\n}\n', 1)[0]
    assert 'ASSUME_YES' not in helper
    result = subprocess.run(['bash', '-c', 'source "$1"; DRY_RUN=1; confirm_existing_tool test', 'test', str(lib)], capture_output=True, text=True)
    assert result.returncode == 0 and 'DRY-RUN' in result.stdout
    result = subprocess.run(['bash', '-c', 'source "$1"; ASSUME_YES=1; DRY_RUN=0; confirm_existing_tool test', 'test', str(lib)],
                            capture_output=True, text=True, start_new_session=True)
    assert result.returncode != 0 and '--yes' in result.stderr
print('PASS: fresh install, detection, approvals, refusals, backup ordering, unmanaged installs and skip-apt')
