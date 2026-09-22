#!/usr/bin/env python3
"""Unit-test the DOCKER-USER sync logic with a stateful mock iptables.

No real firewall is touched: mock iptables records rules to files and emulates
just enough of -L/-A/-D/-I/-N/-F for the sync + idempotency checks.
"""
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
helper = Path(ROOT, "ghost-origin.sh").read_text()
m = re.search(r'cat > "\$\{PREFIX\}/sbin/cf-ufw-update" <<\'EOF\'\n(.*?)\nEOF\n', helper, re.S)
assert m, "cf-ufw-update helper not found"
# Keep only the definitions above the executable part (before `tmp=...`).
defs = m.group(1).split('\ntmp="$(mktemp -d)"', 1)[0]

MOCK = r'''
STATE="$STATEDIR"
mkiptables() {
  local fam="$1"; shift
  local chainfile="${STATE}/${fam}.DOCKER-USER"
  local ownfile="${STATE}/${fam}.OWN"
  touch "${chainfile}" "${ownfile}"
  case "$1" in
    -L)
      local chain="$2"
      if [[ "${3:-} ${4:-}" == *"--line-numbers"* ]]; then
        [[ "${chain}" == "DOCKER-USER" ]] && nl -ba -w1 -s' ' "${chainfile}" || true
        return 0
      fi
      # plain existence check (-L CHAIN -n)
      return 0 ;;
    -N) return 0 ;;
    -F) : > "${ownfile}"; return 0 ;;
    -A) shift; printf '%s\n' "$*" >> "${ownfile}"; return 0 ;;
    -I) # -I DOCKER-USER <rule...>
      shift 2
      { printf '%s\n' "$*"; cat "${chainfile}"; } > "${chainfile}.tmp" && mv "${chainfile}.tmp" "${chainfile}"
      return 0 ;;
    -D) # -D DOCKER-USER <num>
      local num="$3"
      sed -i "${num}d" "${chainfile}"; return 0 ;;
  esac
  return 0
}
iptables() { mkiptables v4 "$@"; }
ip6tables() { mkiptables v6 "$@"; }
ip() { echo "default via 10.0.0.1 dev eth0"; }
command() { if [[ "$1" == "-v" && ( "$2" == iptables || "$2" == ip6tables || "$2" == ip ) ]]; then return 0; fi; builtin command "$@"; }
logger() { :; }
'''

with tempfile.TemporaryDirectory() as tmp:
    state = Path(tmp) / "state"
    state.mkdir()
    cidr_tmp = Path(tmp) / "run"
    cidr_tmp.mkdir()
    harness = f'''
set -uo pipefail
{defs}
tmp="{cidr_tmp}"
STATEDIR="{state}"
{MOCK}
CF_PORTS="80,443"
ENABLE_IPV6="1"
MANAGE_DOCKER="1"
clean_v4=(173.245.48.0/20 103.21.244.0/22 104.16.0.0/13)
clean_v6=(2400:cb00::/32 2606:4700::/32)
sync_docker
echo "--- run again for idempotency ---"
sync_docker
'''
    r = subprocess.run(["bash", "-c", harness], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr

    v4_own = (state / "v4.OWN").read_text().splitlines()
    v4_chain = (state / "v4.DOCKER-USER").read_text().splitlines()
    v6_own = (state / "v6.OWN").read_text().splitlines()

    # 1. One RETURN per CF cidr, then a final DROP, in order.
    assert v4_own == [
        "GHOST_ORIGIN_DOCKER -s 173.245.48.0/20 -j RETURN",
        "GHOST_ORIGIN_DOCKER -s 103.21.244.0/22 -j RETURN",
        "GHOST_ORIGIN_DOCKER -s 104.16.0.0/13 -j RETURN",
        "GHOST_ORIGIN_DOCKER -j DROP",
    ], v4_own
    # 2. IPv6 chain built too.
    assert v6_own == [
        "GHOST_ORIGIN_DOCKER -s 2400:cb00::/32 -j RETURN",
        "GHOST_ORIGIN_DOCKER -s 2606:4700::/32 -j RETURN",
        "GHOST_ORIGIN_DOCKER -j DROP",
    ], v6_own
    # 3. Exactly one jump in DOCKER-USER after two runs (idempotent).
    assert len(v4_chain) == 1, v4_chain
    jump = v4_chain[0]
    # 4. Jump scoped to ingress iface + web ports + NEW conntrack (protects egress).
    for token in ["-i eth0", "-p tcp", "-m multiport --dports 80,443",
                  "-m conntrack --ctstate NEW", "-j GHOST_ORIGIN_DOCKER"]:
        assert token in jump, (token, jump)

    # 5. Disabled => no-op (fresh state).
    state2 = Path(tmp) / "state2"
    state2.mkdir()
    off = harness.replace(f'STATEDIR="{state}"', f'STATEDIR="{state2}"').replace(
        'MANAGE_DOCKER="1"', 'MANAGE_DOCKER="0"')
    r2 = subprocess.run(["bash", "-c", off], capture_output=True, text=True)
    assert r2.returncode == 0, r2.stderr
    assert not (state2 / "v4.OWN").exists(), "sync_docker must be a no-op when disabled"

print("PASS: docker chain build order, ipv6, idempotent single jump, egress-safe scoping, disabled no-op")
