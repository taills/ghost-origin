#!/usr/bin/env bash
# Unit / dry-run test for ghost-origin.sh without requiring real root.
set -euo pipefail

cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Create a mock ufw command in PATH to simulate UFW output for list-ip and del-ip
mkdir -p "${TMP}/bin"
cat <<'EOF' > "${TMP}/bin/ufw"
#!/usr/bin/env bash
if [[ "$1" == "status" && "${2:-}" == "numbered" ]]; then
  cat <<'OUT'
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 80,443/tcp                 ALLOW IN    173.245.48.0/20            # cf-ufw
[ 2] 22/tcp                     ALLOW IN    1.2.3.4                    # cf-ufw-whitelist
[ 3] Anywhere                   ALLOW IN    1.2.3.4                    # cf-ufw-whitelist:home
[ 4] 8080/tcp                   ALLOW IN    5.6.7.8                    # cf-ufw-whitelist
[ 5] Anywhere (v6)              ALLOW IN    2001:db8::1                # cf-ufw-whitelist
[ 6] 22/tcp (v6)                ALLOW IN    2001:db8::1                # cf-ufw-whitelist:office
[ 7] 22/tcp                     ALLOW IN    192.168.1.50               # cf-ufw-bootstrap
OUT
  exit 0
fi

if [[ "$1" == "--force" && "$2" == "delete" ]]; then
  echo "Deleted rule $3"
  exit 0
fi

if [[ "$1" == "allow" ]]; then
  echo "Rule added"
  exit 0
fi

echo "mock ufw: $*"
exit 0
EOF
chmod +x "${TMP}/bin/ufw"
export PATH="${TMP}/bin:${PATH}"

# Create a modified copy of ghost-origin.sh where need_root is a no-op
sed 's/need_root()/need_root_disabled()/' ghost-origin.sh > "${TMP}/ghost-origin.sh"
cat <<'EOF' | cat - "${TMP}/ghost-origin.sh" > "${TMP}/runner.sh"
need_root() { :; }
EOF
chmod +x "${TMP}/runner.sh"

echo "=== 1. Dry run install ==="
"${TMP}/runner.sh" install --dry-run -y --cf-ports 80,443 --spa-ports tcp/22 --no-bootstrap-ssh

echo "=== 2. Dry run with custom ports and whitelist-ips ==="
"${TMP}/runner.sh" install --dry-run -y --cf-ports 8080 --spa-ports tcp/2222,tcp/3333 --whitelist-ips "10.0.0.1,10.0.0.2" --no-bootstrap-ssh

echo "=== 3. Print help ==="
"${TMP}/runner.sh" --help >/dev/null

echo "=== 4. Test allow-ip (dry run) ==="
"${TMP}/runner.sh" allow-ip 192.168.1.100 --dry-run
"${TMP}/runner.sh" allow-ip 192.168.1.100 --port 22 --dry-run
"${TMP}/runner.sh" allow-ip 192.168.1.100 --port 80,443 --proto tcp --comment "web-dev" --dry-run
"${TMP}/runner.sh" allow-ip 2001:db8::100 --port 22 --dry-run
"${TMP}/runner.sh" allow-ip 10.1.1.1,10.1.1.2 --port 3306 --dry-run

echo "=== 5. Test list-ip ==="
"${TMP}/runner.sh" list-ip

echo "=== 6. Test del-ip ==="
"${TMP}/runner.sh" del-ip 1.2.3.4 --dry-run
"${TMP}/runner.sh" del-ip 1.2.3.4 --port 22 --dry-run
"${TMP}/runner.sh" del-ip 2001:db8::1 --dry-run

echo "=== 7. Test invalid IP / port rejection ==="
if "${TMP}/runner.sh" allow-ip "not_an_ip" >/dev/null 2>&1; then
  echo "Expected failure on bad IP in allow-ip!" >&2
  exit 1
fi
if "${TMP}/runner.sh" allow-ip 1.2.3.4 --port "bad_port" >/dev/null 2>&1; then
  echo "Expected failure on bad port in allow-ip!" >&2
  exit 1
fi
if "${TMP}/runner.sh" del-ip "not_an_ip" >/dev/null 2>&1; then
  echo "Expected failure on bad IP in del-ip!" >&2
  exit 1
fi
if "${TMP}/runner.sh" install --dry-run -y --cf-ports "bad_port" >/dev/null 2>&1; then
  echo "Expected failure on bad cf-ports!" >&2
  exit 1
fi
if "${TMP}/runner.sh" install --dry-run -y --spa-ports "bad_proto" >/dev/null 2>&1; then
  echo "Expected failure on bad spa-ports!" >&2
  exit 1
fi

echo "=== 8. Test non-root prompt & exit on ghost-origin.sh ==="
out="$(./ghost-origin.sh status 2>&1 || true)"
if ! grep -q "权限不足" <<< "${out}"; then
  echo "Expected permission denied prompt in ghost-origin.sh, got: ${out}" >&2
  exit 1
fi

echo "=== All tests passed cleanly! ==="
