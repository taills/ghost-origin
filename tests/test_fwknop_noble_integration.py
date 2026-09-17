#!/usr/bin/env python3
"""Run ONLY inside the disposable Noble test container (no host mounts).
Real fwknop crypto/UDP/config/cycle timer; UFW is a recording stub, not a kernel firewall test.
"""
from pathlib import Path
import os
import subprocess
import time

assert Path('/.dockerenv').exists() and os.geteuid() == 0, 'Use the dedicated test container'
candidate = Path(__file__).resolve().parents[1] / 'ghost-origin.sh'
script_path = candidate if candidate.exists() else Path('/tmp/ghost-origin.sh')
source = script_path.read_text().rsplit('\nmain "$@"', 1)[0]
Path('/tmp/ghost-origin-lib.sh').write_text(source)


def shell(body, ok=True):
    result = subprocess.run(['bash', '-c', 'source /tmp/ghost-origin-lib.sh; ' + body], text=True, capture_output=True)
    assert (result.returncode == 0) == ok, result.stdout + result.stderr
    return result


version = subprocess.check_output(['dpkg-query', '-W', '-f=${Version}', 'fwknop-server'], text=True)
assert version.startswith('2.6.10-'), version
# Reproduce migration from the previous invalid directive, then validate real generated files.
with Path('/etc/fwknop/fwknopd.conf').open('a') as stream:
    stream.write('\nENABLE_IPT_INPUT N;\n')
shell('FW_ACCESS_TIMEOUT=2; generate_keys; write_helpers; write_fwknop_access; configure_fwknopd; validate_fwknop_config; write_client_rc')
config = Path('/etc/fwknop/fwknopd.conf').read_text()
assert '\nENABLE_IPT_INPUT ' not in config
assert 'CMD_CYCLE_TIMER             2' in Path('/etc/fwknop/access.conf').read_text()
# Strict PCAP mode must fail on this distribution build before touching UFW.
shell('SPA_MODE=pcap; configure_fwknopd; validate_fwknop_config', ok=False)
shell('SPA_MODE=udp; configure_fwknopd; validate_fwknop_config')
# Missing CMD_CYCLE_TIMER must be detected by the actual parser.
access = Path('/etc/fwknop/access.conf')
valid = access.read_text()
access.write_text('\n'.join(line for line in valid.splitlines() if not line.startswith('CMD_CYCLE_TIMER')) + '\n')
shell('validate_fwknop_config', ok=False)
access.write_text(valid)
# Record UFW invocations to test real command-cycle callbacks without NET_ADMIN.
ufw = Path('/usr/sbin/ufw')
ufw.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> /tmp/ufw-calls\n')
ufw.chmod(0o755)
log = Path('/tmp/ufw-calls')
log.write_text('')
shell('RESET_UFW=0; SPA_MODE=udp; configure_ufw_policy')
assert 'allow proto udp from 0.0.0.0/0 to any port 62201 comment ghost-origin-spa' in log.read_text()
log.write_text('')
shell('RESET_UFW=0; SPA_MODE=pcap; configure_ufw_policy')
assert 'port 62201' not in log.read_text()
log.write_text('')
# Use generated client settings, but replace server address and disable external IP resolution.
rc = Path('/root/fwknop-client.rc')
lines = [line for line in rc.read_text().splitlines() if not line.startswith(('SPA_SERVER ', 'RESOLVE_IP_HTTPS'))]
lines.append('SPA_SERVER 127.0.0.1')
rc.write_text('\n'.join(lines) + '\n')
logfile = Path('/tmp/fwknop-test.log').open('w')
daemon = subprocess.Popen(['fwknopd', '-f', '-v'], stdout=logfile, stderr=subprocess.STDOUT)
try:
    # Bounded readiness wait; not a subagent polling loop.
    for _ in range(50):
        assert daemon.poll() is None, 'fwknopd exited before readiness'
        if 'Kicking off UDP server' in Path('/tmp/fwknop-test.log').read_text():
            break
        time.sleep(0.1)
    else:
        raise AssertionError('UDP daemon did not start')
    # Invalid UDP traffic must not create an access rule.
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.sendto(b'invalid SPA payload', ('127.0.0.1', 62201))
    time.sleep(0.3)
    assert log.read_text() == ''
    result = subprocess.run(['fwknop', '--rc-file', str(rc), '-n', 'ghost-origin', '-a', '127.0.0.1'], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    for _ in range(100):
        calls = log.read_text()
        if '--force delete allow proto tcp from 127.0.0.1 to any port 22' in calls:
            break
        assert daemon.poll() is None, 'fwknopd exited while processing SPA'
        time.sleep(0.1)
    else:
        raise AssertionError('Expected real authenticated SPA open/close callbacks; inspect /tmp/fwknop-test.log inside container')
    assert 'allow proto tcp from 127.0.0.1 to any port 22 comment fwknop' in calls
finally:
    daemon.terminate()
    daemon.wait(timeout=5)
    logfile.close()
print('PASS: Noble ' + version + ': config parse, unsupported PCAP rejection, UDP reception, invalid SPA rejection, authenticated open and timed close (UFW stub)')
