#!/usr/bin/env bash
# Unit / dry-run test for install.sh without requiring real root.
set -euo pipefail

cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Create a modified copy of install.sh where need_root is a no-op
sed 's/need_root()/need_root_disabled()/' install.sh > "${TMP}/install.sh"
# prepend fake need_root
cat <<'EOF' | cat - "${TMP}/install.sh" > "${TMP}/runner.sh"
need_root() { :; }
EOF
chmod +x "${TMP}/runner.sh"

echo "=== 1. Dry run install ==="
"${TMP}/runner.sh" install --dry-run -y --cf-ports 80,443 --spa-ports tcp/22 --no-bootstrap-ssh

echo "=== 2. Dry run with custom ports ==="
"${TMP}/runner.sh" install --dry-run -y --cf-ports 8080 --spa-ports tcp/2222,tcp/3333 --no-bootstrap-ssh

echo "=== 3. Print help ==="
"${TMP}/runner.sh" --help >/dev/null

echo "=== 4. Test port validation ==="
if "${TMP}/runner.sh" install --dry-run -y --cf-ports "bad_port" >/dev/null 2>&1; then
  echo "Expected failure on bad cf-ports!" >&2
  exit 1
fi
if "${TMP}/runner.sh" install --dry-run -y --spa-ports "bad_proto" >/dev/null 2>&1; then
  echo "Expected failure on bad spa-ports!" >&2
  exit 1
fi

echo "=== All tests passed cleanly! ==="
