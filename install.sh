#!/usr/bin/env bash
# cf-ufw-quickstart — UFW default-deny + Cloudflare 80/443 + fwknop SPA
#
# Incoming policy:
#   - allow Cloudflare IPv4/IPv6 -> TCP 80,443
#   - allow established/related (UFW default)
#   - deny everything else
#   - fwknop SPA temporarily opens requested ports (default tcp/22) via UFW
#
# SPA UDP/62201 is intentionally NOT allowed in UFW. fwknopd sniffs with
# libpcap before the INPUT drop, so the knock port stays dark.
set -euo pipefail

readonly SCRIPT_NAME="cf-ufw-quickstart"
readonly SCRIPT_VERSION="1.0.0"
readonly PREFIX="/usr/local"
readonly CONF_DIR="/etc/cf-ufw-quickstart"
readonly CONF_FILE="${CONF_DIR}/config"
readonly UFW_COMMENT="cf-ufw"
readonly BOOTSTRAP_COMMENT="cf-ufw-bootstrap"
readonly FWKNOP_COMMENT="fwknop"
readonly WHITELIST_COMMENT="cf-ufw-whitelist"
readonly CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
readonly CF_IPV6_URL="https://www.cloudflare.com/ips-v6"
readonly CF_API_URL="https://api.cloudflare.com/client/v4/ips"
readonly ACCESS_CONF="/etc/fwknop/access.conf"
readonly FWKNOPD_CONF="/etc/fwknop/fwknopd.conf"
readonly KEY_FILE="/root/fwknop-client.rc"
readonly KEY_BACKUP_DIR="/root/cf-ufw-quickstart-backup"

CF_PORTS="${CF_PORTS:-80,443}"
SPA_PORTS="${SPA_PORTS:-tcp/22}"
SSH_PORT="${SSH_PORT:-22}"
FW_ACCESS_TIMEOUT="${FW_ACCESS_TIMEOUT:-60}"
SPA_UDP_PORT="${SPA_UDP_PORT:-62201}"
ALLOW_SSH_FROM="${ALLOW_SSH_FROM:-}"
WHITELIST_IPS="${WHITELIST_IPS:-}"
BOOTSTRAP_SSH="${BOOTSTRAP_SSH:-auto}"
ASSUME_YES=0
DRY_RUN=0
SKIP_APT=0
FORCE_KEYS=0
ENABLE_UFW=1
ENABLE_IPV6=1
RESET_UFW=1
CMD="install"
FWKNOP_UNIT="fwknop-server"
KEY_BASE64=""
HMAC_KEY_BASE64=""
TARGET_IP=""
TARGET_PORT=""
TARGET_PROTO=""
TARGET_NOTE=""

log()  { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"; }
warn() { printf '[%s] WARN: %s\n' "${SCRIPT_NAME}" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 1; }

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "请用 root 运行: sudo $0 ..."
}

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}

用法:
  $0 install [选项]                 安装并配置 ufw + fwknop（默认）
  $0 allow-ip <IP[/CIDR]> [选项]     添加白名单 IP（放行访问，免敲门）
  $0 del-ip <IP[/CIDR]> [选项]       删除白名单 IP 规则
  $0 list-ip                        查看当前白名单 IP 列表
  $0 update-cf                      刷新 Cloudflare IP 放行规则
  $0 status                         查看防火墙 / fwknop 状态
  $0 print-client                   打印敲门客户端配置
  $0 uninstall                      移除本脚本写入的规则与辅助文件（不关闭 UFW）

白名单管理选项 (allow-ip / del-ip):
  --ip IP                    要操作的 IP 或 CIDR（也可直接作为位置参数）
  --port, --ports PORT       指定放行端口（如 22 或 80,443；默认全端口 any）
  --proto PROTO              指定协议（tcp / udp / any；默认 tcp，全端口时默认 any）
  --comment, --note NOTE     自定义备注（附加在 ${WHITELIST_COMMENT}: 之后）

安装选项:
  --cf-ports 80,443          Cloudflare 放行的 TCP 端口（默认 80,443）
  --spa-ports tcp/22         fwknop 允许请求打开的端口（默认 tcp/22）
  --ssh-port 22              用于防锁死的 SSH 端口
  --timeout 60               SPA 打开时长（秒）
  --allow-ssh-from IP        永久放行该 IP 的 SSH（不推荐，仅应急）
  --whitelist-ips "IP1,IP2"  安装时初始添加的白名单 IP 列表
  --bootstrap-ssh            从当前 SSH 来源 IP 临时放行 SSH（默认：检测到 SSH 则开启）
  --no-bootstrap-ssh         不添加 SSH 应急规则（可能把自己锁在门外）
  --no-ufw-enable            只写规则，不执行 ufw --force enable
  --keep-ufw-rules           不执行 ufw reset（保留现有规则，仍会改默认策略）
  --no-ipv6                  不处理 IPv6 / 不放行 Cloudflare IPv6
  --skip-apt                 跳过 apt 安装
  --force-keys               重新生成 fwknop 密钥（覆盖旧密钥）
  --yes, -y                  非交互
  --dry-run                  只打印将执行的命令
  -h, --help                 帮助

环境变量可覆盖同名默认值: CF_PORTS SPA_PORTS SSH_PORT FW_ACCESS_TIMEOUT ALLOW_SSH_FROM WHITELIST_IPS
EOF
}

parse_args() {
  CMD="install"
  if [[ "${#}" -gt 0 && "$1" != -* ]]; then
    CMD="$1"
    shift
  fi
  case "${CMD}" in
    install|update-cf|status|print-client|uninstall|allow-ip|add-ip|add-whitelist|del-ip|delete-ip|remove-ip|whitelist-del|list-ip|list-whitelist|whitelist|help|-h|--help) ;;
    *) die "未知子命令: ${CMD}" ;;
  esac
  case "${CMD}" in
    allow-ip|add-ip|add-whitelist|del-ip|delete-ip|remove-ip|whitelist-del)
      if [[ "${#}" -gt 0 && "$1" != -* ]]; then
        TARGET_IP="$1"
        shift
      fi
      ;;
  esac
  while [[ "${#}" -gt 0 ]]; do
    case "$1" in
      --ip) TARGET_IP="${2:?}"; shift 2 ;;
      --port|--ports) TARGET_PORT="${2:?}"; shift 2 ;;
      --proto) TARGET_PROTO="${2:?}"; shift 2 ;;
      --comment|--note) TARGET_NOTE="${2:?}"; shift 2 ;;
      --whitelist-ips) WHITELIST_IPS="${2:?}"; shift 2 ;;
      --cf-ports) CF_PORTS="${2:?}"; shift 2 ;;
      --spa-ports) SPA_PORTS="${2:?}"; shift 2 ;;
      --ssh-port) SSH_PORT="${2:?}"; shift 2 ;;
      --timeout) FW_ACCESS_TIMEOUT="${2:?}"; shift 2 ;;
      --allow-ssh-from) ALLOW_SSH_FROM="${2:?}"; shift 2 ;;
      --bootstrap-ssh) BOOTSTRAP_SSH="yes"; shift ;;
      --no-bootstrap-ssh) BOOTSTRAP_SSH="no"; shift ;;
      --no-ufw-enable) ENABLE_UFW=0; shift ;;
      --keep-ufw-rules) RESET_UFW=0; shift ;;
      --no-ipv6) ENABLE_IPV6=0; shift ;;
      --skip-apt) SKIP_APT=1; shift ;;
      --force-keys) FORCE_KEYS=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ufw_cidrs_with_comment() {
  local comment="$1"
  ufw status | awk -v c="# ${comment}" '
    index($0, c) {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      n = split(line, a, /[[:space:]]+/)
      ip = a[n]
      if (ip == "(v6)" && n > 1) ip = a[n-1]
      if (ip != "" && ip != "Anywhere") print ip
    }' | sort -u
}

default_iface() {
  ip -4 route show default 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

current_ssh_ip() {
  local ip=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="${SSH_CONNECTION%% *}"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    ip="${SSH_CLIENT%% *}"
  fi
  printf '%s\n' "${ip}"
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; }
is_ipv6() { [[ "$1" == *:* ]]; }

validate_ports_csv() {
  local csv="$1"
  [[ "${csv}" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "端口列表无效: ${csv}（示例: 80,443）"
}

validate_spa_ports() {
  local csv="$1" item
  IFS=',' read -ra items <<< "${csv}"
  for item in "${items[@]}"; do
    item="${item// /}"
    [[ "${item}" =~ ^(tcp|udp)/[0-9]+$ ]] || die "SPA 端口无效: ${item}（示例: tcp/22 或 tcp/22,tcp/2222）"
  done
}

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  local ans
  read -r -p "${prompt} [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]]
}

backup_file() {
  local src="$1"
  [[ -f "${src}" ]] || return 0
  run mkdir -p "${KEY_BACKUP_DIR}"
  run cp -a "${src}" "${KEY_BACKUP_DIR}/$(basename "${src}").$(date +%Y%m%d%H%M%S)"
}

install_packages() {
  [[ "${SKIP_APT}" -eq 1 ]] && return 0
  have_cmd apt-get || die "当前仅支持 Debian/Ubuntu（需要 apt-get）"
  export DEBIAN_FRONTEND=noninteractive
  log "安装 ufw / fwknop-server / fwknop-client ..."
  run apt-get update -y
  run apt-get install -y --no-install-recommends \
    ufw fwknop-server fwknop-client curl ca-certificates iproute2 python3
  detect_fwknop_unit
}

detect_fwknop_unit() {
  FWKNOP_UNIT="fwknop-server"
  if have_cmd systemctl; then
    if systemctl list-unit-files fwknop-server.service >/dev/null 2>&1; then
      FWKNOP_UNIT="fwknop-server"
    elif systemctl list-unit-files fwknopd.service >/dev/null 2>&1; then
      FWKNOP_UNIT="fwknopd"
    fi
  fi
}

ufw_delete_by_comment() {
  local comment="$1"
  local nums n
  mapfile -t nums < <(ufw status numbered | awk -v c="# ${comment}" '
    index($0, c) {
      if (match($0, /\[[[:space:]]*[0-9]+\]/)) {
        n = substr($0, RSTART + 1, RLENGTH - 2)
        gsub(/[[:space:]]/, "", n)
        print n
      }
    }' | sort -nr)
  for n in "${nums[@]}"; do
    [[ -n "${n}" ]] || continue
    run ufw --force delete "${n}" >/dev/null 2>&1 || true
  done
}

write_conf() {
  run mkdir -p "${CONF_DIR}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "将写入 ${CONF_FILE}"
    return 0
  fi
  cat > "${CONF_FILE}" <<EOF
# generated by ${SCRIPT_NAME} ${SCRIPT_VERSION}
CF_PORTS=${CF_PORTS}
SPA_PORTS=${SPA_PORTS}
SSH_PORT=${SSH_PORT}
FW_ACCESS_TIMEOUT=${FW_ACCESS_TIMEOUT}
SPA_UDP_PORT=${SPA_UDP_PORT}
ENABLE_IPV6=${ENABLE_IPV6}
UFW_COMMENT=${UFW_COMMENT}
CF_IPV4_URL=${CF_IPV4_URL}
CF_IPV6_URL=${CF_IPV6_URL}
CF_API_URL=${CF_API_URL}
EOF
  chmod 600 "${CONF_FILE}"
}

load_conf() {
  [[ -f "${CONF_FILE}" ]] || return 0
  # shellcheck disable=SC1090
  source "${CONF_FILE}"
}

write_helpers() {
  run mkdir -p "${PREFIX}/sbin"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "将安装辅助脚本到 ${PREFIX}/sbin"
    return 0
  fi

  cat > "${PREFIX}/sbin/fwknop-ufw-open" <<EOF
#!/usr/bin/env bash
# Called by fwknopd CMD_CYCLE_OPEN: args are taken from SPA payload.
set -euo pipefail
SRC="\${1:-}"
PROTO="\${2:-tcp}"
PORTS="\${3:-}"
COMMENT="${FWKNOP_COMMENT}"
EOF
  cat >> "${PREFIX}/sbin/fwknop-ufw-open" <<'EOF'

ufw_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    /usr/sbin/ufw "$@"
  else
    sudo -n /usr/sbin/ufw "$@"
  fi
}

if [[ -z "${SRC}" || -z "${PORTS}" ]]; then
  echo "usage: $0 <src-ip> <proto> <port[,port...]>" >&2
  exit 1
fi

PROTO="${PROTO,,}"
PORTS="${PORTS// /}"
PORTS="${PORTS#tcp/}"
PORTS="${PORTS#udp/}"

IFS=',' read -ra plist <<< "${PORTS}"
for p in "${plist[@]}"; do
  p="${p#tcp/}"
  p="${p#udp/}"
  [[ "${p}" =~ ^[0-9]+$ ]] || continue
  ufw_cmd allow proto "${PROTO}" from "${SRC}" to any port "${p}" comment "${COMMENT}" >/dev/null
  logger -t fwknop-ufw "open ${PROTO}/${p} from ${SRC}"
done
EOF

  cat > "${PREFIX}/sbin/fwknop-ufw-close" <<'EOF'
#!/usr/bin/env bash
# Called by fwknopd CMD_CYCLE_CLOSE. Never fail the daemon on a missing rule.
set -u
SRC="${1:-}"
PROTO="${2:-tcp}"
PORTS="${3:-}"

ufw_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    /usr/sbin/ufw "$@"
  else
    sudo -n /usr/sbin/ufw "$@"
  fi
}

if [[ -z "${SRC}" || -z "${PORTS}" ]]; then
  exit 0
fi

PROTO="${PROTO,,}"
PORTS="${PORTS// /}"

IFS=',' read -ra plist <<< "${PORTS}"
for p in "${plist[@]}"; do
  p="${p#tcp/}"
  p="${p#udp/}"
  [[ "${p}" =~ ^[0-9]+$ ]] || continue
  ufw_cmd --force delete allow proto "${PROTO}" from "${SRC}" to any port "${p}" >/dev/null 2>&1 || true
  logger -t fwknop-ufw "close ${PROTO}/${p} from ${SRC}"
done
exit 0
EOF

  cat > "${PREFIX}/sbin/cf-ufw-update" <<'EOF'
#!/usr/bin/env bash
# Refresh UFW allow rules for Cloudflare published IP ranges.
set -euo pipefail
CONF_FILE="/etc/cf-ufw-quickstart/config"
[[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}"

CF_PORTS="${CF_PORTS:-80,443}"
ENABLE_IPV6="${ENABLE_IPV6:-1}"
UFW_COMMENT="${UFW_COMMENT:-cf-ufw}"
CF_IPV4_URL="${CF_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
CF_IPV6_URL="${CF_IPV6_URL:-https://www.cloudflare.com/ips-v6}"
CF_API_URL="${CF_API_URL:-https://api.cloudflare.com/client/v4/ips}"

log() { printf '[cf-ufw-update] %s\n' "$*"; }
die() { printf '[cf-ufw-update] ERROR: %s\n' "$*" >&2; exit 1; }

fetch() {
  curl -fsSL --max-time 20 "$1"
}

is_v4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
is_v6() { [[ "$1" == *:* && "$1" == */* ]]; }

fetch_plain() {
  local v4 v6
  if v4="$(fetch "${CF_IPV4_URL}")"; then
    printf '%s\n' "${v4}" > "${tmp}/v4"
  else
    return 1
  fi
  if v6="$(fetch "${CF_IPV6_URL}")"; then
    printf '%s\n' "${v6}" > "${tmp}/v6"
  else
    : > "${tmp}/v6"
  fi
  return 0
}

fetch_lists() {
  fetch_plain && return 0
  log "主列表失败，尝试 Cloudflare API ..."
  fetch "${CF_API_URL}" > "${tmp}/ips.json" || return 1
  python3 - "${tmp}/ips.json" "${tmp}/v4" "${tmp}/v6" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
result = data.get("result") or data
ipv4 = result.get("ipv4_cidrs") or []
ipv6 = result.get("ipv6_cidrs") or []
open(sys.argv[2], "w").write("\n".join(ipv4) + ("\n" if ipv4 else ""))
open(sys.argv[3], "w").write("\n".join(ipv6) + ("\n" if ipv6 else ""))
PY
}

current_comment_cidrs() {
  # IPv6 lines look like: 80,443/tcp  ALLOW  Anywhere (v6)  # cf-ufw
  # IPv4 lines look like: 80,443/tcp  ALLOW  173.245.48.0/20  # cf-ufw
  ufw status | awk -v c="# ${UFW_COMMENT}" '
    index($0, c) {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      n = split(line, a, /[[:space:]]+/)
      ip = a[n]
      if (ip == "(v6)" && n > 1) ip = a[n-1]
      if (ip != "" && ip != "Anywhere") print ip
    }'
}

add_rule() {
  local cidr="$1"
  /usr/sbin/ufw allow proto tcp from "${cidr}" to any port "${CF_PORTS}" comment "${UFW_COMMENT}" >/dev/null
}

delete_rule() {
  local cidr="$1"
  /usr/sbin/ufw --force delete allow proto tcp from "${cidr}" to any port "${CF_PORTS}" >/dev/null 2>&1 || true
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

command -v ufw >/dev/null || die "未找到 ufw"
command -v curl >/dev/null || die "未找到 curl"
fetch_lists || die "无法下载 Cloudflare IP 列表"

mapfile -t new_v4 < <(awk 'NF && $1 !~ /^#/' "${tmp}/v4" | tr -d '\r')
mapfile -t new_v6 < <(awk 'NF && $1 !~ /^#/' "${tmp}/v6" | tr -d '\r')

clean_v4=()
for cidr in "${new_v4[@]}"; do
  is_v4 "${cidr}" && clean_v4+=("${cidr}")
done
clean_v6=()
for cidr in "${new_v6[@]}"; do
  is_v6 "${cidr}" && clean_v6+=("${cidr}")
done

(( ${#clean_v4[@]} >= 5 )) || die "IPv4 列表异常（${#clean_v4[@]} 条），中止以免清空现有规则"

wanted=("${clean_v4[@]}")
if [[ "${ENABLE_IPV6}" == "1" || "${ENABLE_IPV6}" -eq 1 ]]; then
  wanted+=("${clean_v6[@]}")
fi

declare -A want_map=()
for cidr in "${wanted[@]}"; do
  want_map["${cidr}"]=1
done

mapfile -t existing < <(current_comment_cidrs | sort -u)
declare -A have_map=()
for cidr in "${existing[@]}"; do
  [[ -n "${cidr}" ]] || continue
  have_map["${cidr}"]=1
done

added=0
removed=0
for cidr in "${wanted[@]}"; do
  if [[ -z "${have_map[${cidr}]+x}" ]]; then
    add_rule "${cidr}"
    added=$((added + 1))
  fi
done
for cidr in "${existing[@]}"; do
  [[ -n "${cidr}" ]] || continue
  if [[ -z "${want_map[${cidr}]+x}" ]]; then
    delete_rule "${cidr}"
    removed=$((removed + 1))
  fi
done

log "Cloudflare 规则已同步: 目标 ${#wanted[@]} 条（v4=${#clean_v4[@]} v6=${#clean_v6[@]}）, 新增 ${added}, 删除 ${removed}"
logger -t cf-ufw-update "synced ${#wanted[@]} cidrs, added=${added}, removed=${removed}"
EOF

  chmod 755 "${PREFIX}/sbin/fwknop-ufw-open" \
            "${PREFIX}/sbin/fwknop-ufw-close" \
            "${PREFIX}/sbin/cf-ufw-update"
}

write_systemd_timer() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "将安装 systemd 定时器 cf-ufw-update.timer"
    return 0
  fi
  cat > /etc/systemd/system/cf-ufw-update.service <<EOF
[Unit]
Description=Refresh UFW rules for Cloudflare IP ranges
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PREFIX}/sbin/cf-ufw-update
EOF

  cat > /etc/systemd/system/cf-ufw-update.timer <<'EOF'
[Unit]
Description=Daily Cloudflare UFW IP refresh

[Timer]
OnBootSec=2min
OnUnitActiveSec=1d
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  run systemctl daemon-reload
  run systemctl enable --now cf-ufw-update.timer
}

generate_keys() {
  local gen_file="/etc/fwknop/${SCRIPT_NAME}.keys"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    KEY_BASE64="DRYRUN_KEY"
    HMAC_KEY_BASE64="DRYRUN_HMAC"
    log "dry-run: 跳过密钥生成"
    return 0
  fi
  if [[ -f "${gen_file}" && "${FORCE_KEYS}" -eq 0 ]]; then
    log "复用已有密钥 ${gen_file}（需要重新生成请加 --force-keys）"
  else
    backup_file "${gen_file}"
    log "生成 fwknop HMAC 密钥 ..."
    fwknop --key-gen --use-hmac --key-len 64 --hmac-key-len 64 --key-gen-file "${gen_file}"
    chmod 600 "${gen_file}"
  fi

  local key hmac
  key="$(awk '/^KEY_BASE64/ {print $2; exit}' "${gen_file}")"
  hmac="$(awk '/^HMAC_KEY_BASE64/ {print $2; exit}' "${gen_file}")"
  [[ -n "${key}" && -n "${hmac}" ]] || die "无法从 ${gen_file} 读取密钥"
  KEY_BASE64="${key}"
  HMAC_KEY_BASE64="${hmac}"
}

write_fwknop_access() {
  backup_file "${ACCESS_CONF}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "将写入 ${ACCESS_CONF}"
    return 0
  fi
  cat > "${ACCESS_CONF}" <<EOF
# generated by ${SCRIPT_NAME}
# Native iptables chains are not used; UFW is driven via command cycles so
# this works with both iptables-legacy and nft UFW backends.

SOURCE                      ANY
OPEN_PORTS                  ${SPA_PORTS}
REQUIRE_SOURCE_ADDRESS      Y
FW_ACCESS_TIMEOUT           ${FW_ACCESS_TIMEOUT}
KEY_BASE64                  ${KEY_BASE64}
HMAC_KEY_BASE64             ${HMAC_KEY_BASE64}
CMD_CYCLE_OPEN              ${PREFIX}/sbin/fwknop-ufw-open \$SRC \$PROTO \$PORT
CMD_CYCLE_CLOSE             ${PREFIX}/sbin/fwknop-ufw-close \$SRC \$PROTO \$PORT
EOF
  chmod 600 "${ACCESS_CONF}"
}

set_fwknopd_var() {
  local key="$1" val="$2"
  local file="${FWKNOPD_CONF}"
  [[ -f "${file}" ]] || die "找不到 ${file}，fwknop-server 是否已安装？"
  if grep -qE "^[#;[:space:]]*${key}[[:space:]]" "${file}"; then
    sed -i -E "s|^[#;[:space:]]*${key}[[:space:]].*|${key}    ${val};|" "${file}"
  else
    printf '%s    %s;\n' "${key}" "${val}" >> "${file}"
  fi
}

configure_fwknopd() {
  backup_file "${FWKNOPD_CONF}"
  local iface
  iface="$(default_iface)"
  [[ -n "${iface}" ]] || die "无法检测默认路由网卡，请手动设置 ${FWKNOPD_CONF} 中的 PCAP_INTF"
  log "fwknopd 监听网卡: ${iface}（UDP/${SPA_UDP_PORT}，UFW 不放行该端口）"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi

  set_fwknopd_var "PCAP_INTF" "${iface}"
  set_fwknopd_var "ENABLE_PCAP_PROMISC" "N"
  set_fwknopd_var "PCAP_FILTER" "udp port ${SPA_UDP_PORT}"
  # CMD_CYCLE 负责改 UFW；关掉原生 iptables 注入，避免和 UFW/nft 抢链。
  set_fwknopd_var "ENABLE_IPT_INPUT" "N"
  set_fwknopd_var "ENABLE_IPT_OUTPUT" "N"
  set_fwknopd_var "ENABLE_IPT_FORWARDING" "N"
}

write_client_rc() {
  local server_ip
  server_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  server_ip="${server_ip:-YOUR_SERVER_IP}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "将写入客户端配置 ${KEY_FILE}"
    return 0
  fi
  cat > "${KEY_FILE}" <<EOF
# fwknop client stanza — copy to ~/.fwknoprc on your laptop
# 先敲门再 SSH:  fwknop -n ${SCRIPT_NAME} && ssh user@${server_ip}

[${SCRIPT_NAME}]
SPA_SERVER          ${server_ip}
ACCESS              ${SPA_PORTS%%,*}
KEY_BASE64          ${KEY_BASE64}
HMAC_KEY_BASE64     ${HMAC_KEY_BASE64}
USE_HMAC            Y
RESOLVE_IP_HTTPS    Y
EOF
  chmod 600 "${KEY_FILE}"
}

configure_ufw_policy() {
  log "配置 UFW：默认拒绝入站，允许出站，仅 Cloudflare -> ${CF_PORTS}/tcp"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi

  if [[ "${ENABLE_IPV6}" -eq 1 ]]; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  else
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  fi

  if [[ "${RESET_UFW}" -eq 1 ]]; then
    warn "执行 ufw --force reset，现有 UFW 规则会被清空"
    ufw --force reset >/dev/null
  fi
  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny routed
  ufw logging low

  # 回环由 /etc/ufw/before.rules 默认放行。
  # 不放行 UDP 62201，保持 SPA 端口对外不可见。
}

apply_bootstrap_ssh() {
  local ip="${ALLOW_SSH_FROM}"
  if [[ -n "${ip}" ]]; then
    is_ipv4 "${ip}" || is_ipv6 "${ip}" || die "--allow-ssh-from 不是合法 IP: ${ip}"
    log "应急放行 SSH: ${ip} -> tcp/${SSH_PORT}"
    [[ "${DRY_RUN}" -eq 1 ]] && return 0
    ufw allow proto tcp from "${ip}" to any port "${SSH_PORT}" comment "${BOOTSTRAP_COMMENT}"
    return 0
  fi

  local ssh_ip
  ssh_ip="$(current_ssh_ip)"
  if [[ "${BOOTSTRAP_SSH}" == "no" ]]; then
    warn "未添加 SSH 应急规则。启用 UFW 后，新 SSH 必须先 fwknop 敲门。"
    return 0
  fi
  if [[ "${BOOTSTRAP_SSH}" == "auto" && -z "${ssh_ip}" ]]; then
    warn "未检测到 SSH_CONNECTION，跳过应急 SSH 规则。"
    return 0
  fi
  if [[ "${BOOTSTRAP_SSH}" == "yes" || "${BOOTSTRAP_SSH}" == "auto" ]]; then
    [[ -n "${ssh_ip}" ]] || die "--bootstrap-ssh 需要能检测到当前 SSH 来源 IP，或改用 --allow-ssh-from"
    log "临时放行当前 SSH 来源 ${ssh_ip} -> tcp/${SSH_PORT}（验证敲门成功后请删除）"
    [[ "${DRY_RUN}" -eq 1 ]] && return 0
    ufw allow proto tcp from "${ssh_ip}" to any port "${SSH_PORT}" comment "${BOOTSTRAP_COMMENT}"
  fi
}

apply_initial_whitelist() {
  [[ -n "${WHITELIST_IPS}" ]] || return 0
  log "配置安装初始白名单 IP: ${WHITELIST_IPS}"
  local saved_ip="${TARGET_IP}" saved_port="${TARGET_PORT}" saved_proto="${TARGET_PROTO}" saved_note="${TARGET_NOTE}"
  TARGET_IP="${WHITELIST_IPS}"
  TARGET_PORT=""
  TARGET_PROTO=""
  TARGET_NOTE="initial"
  cmd_allow_ip
  TARGET_IP="${saved_ip}"
  TARGET_PORT="${saved_port}"
  TARGET_PROTO="${saved_proto}"
  TARGET_NOTE="${saved_note}"
}

cmd_allow_ip() {
  need_root
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    have_cmd ufw || die "ufw 未安装"
  fi
  [[ -n "${TARGET_IP}" ]] || die "缺少 IP 地址。用法: $0 allow-ip <IP[/CIDR]> [--port <端口>] [--proto <协议>] [--comment <备注>]"

  local proto="${TARGET_PROTO:-}"
  local ports="${TARGET_PORT:-}"
  local note="${TARGET_NOTE:-}"

  local comment="${WHITELIST_COMMENT}"
  if [[ -n "${note}" ]]; then
    comment="${WHITELIST_COMMENT}:${note}"
  fi

  IFS=',' read -ra ip_list <<< "${TARGET_IP}"
  for ip in "${ip_list[@]}"; do
    ip="${ip// /}"
    [[ -n "${ip}" ]] || continue
    is_ipv4 "${ip}" || is_ipv6 "${ip}" || die "非法的 IP/CIDR 地址: ${ip}"

    if [[ -z "${ports}" || "${ports}" == "all" || "${ports}" == "any" ]]; then
      log "添加白名单规则: 允许 ${ip} 访问所有端口"
      run ufw allow from "${ip}" comment "${comment}"
    else
      local use_proto="${proto:-tcp}"
      use_proto="${use_proto,,}"
      IFS=',' read -ra plist <<< "${ports}"
      for p in "${plist[@]}"; do
        p="${p// /}"
        [[ "${p}" =~ ^[0-9]+(:[0-9]+)?$ ]] || die "非法端口格式: ${p}（支持单端口如 22 或端口范围如 8000:8080）"
        if [[ "${use_proto}" == "any" || "${use_proto}" == "all" ]]; then
          log "添加白名单规则: 允许 ${ip} 访问端口 ${p} (所有协议)"
          run ufw allow from "${ip}" to any port "${p}" comment "${comment}"
        else
          log "添加白名单规则: 允许 ${ip} 访问端口 ${p}/${use_proto}"
          run ufw allow proto "${use_proto}" from "${ip}" to any port "${p}" comment "${comment}"
        fi
      done
    fi
  done
  log "白名单规则添加完成。"
}

cmd_del_ip() {
  need_root
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    have_cmd ufw || die "ufw 未安装"
  fi
  [[ -n "${TARGET_IP}" ]] || die "缺少要删除的 IP 地址。用法: $0 del-ip <IP[/CIDR]> [--port <端口>]"

  local target_port="${TARGET_PORT:-}"
  [[ "${target_port}" == "all" || "${target_port}" == "any" ]] && target_port=""

  IFS=',' read -ra ip_list <<< "${TARGET_IP}"
  for ip in "${ip_list[@]}"; do
    ip="${ip// /}"
    [[ -n "${ip}" ]] || continue
    is_ipv4 "${ip}" || is_ipv6 "${ip}" || die "非法的 IP/CIDR 地址: ${ip}"

    log "检索 IP [${ip}] ${target_port:+端口 [${target_port}] }相关的白名单规则..."

    mapfile -t rule_nums < <(ufw status numbered 2>/dev/null | awk \
      -v tip="${ip}" \
      -v tport="${target_port}" \
      -v cpfx="${WHITELIST_COMMENT}" \
      -v bpfx="${BOOTSTRAP_COMMENT}" '
      {
        line = $0
        if (!match(line, /\[[[:space:]]*([0-9]+)\]/)) next
        rnum = substr(line, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", rnum)

        comm = ""
        if (match(line, /#[[:space:]]*.*/)) {
          comm = substr(line, RSTART + 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", comm)
          line = substr(line, 1, RSTART - 1)
        }

        if (index(comm, cpfx) != 1 && index(comm, bpfx) != 1) next

        gsub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
        gsub(/[[:space:]]+$/, "", line)

        n = split(line, a, /[[:space:]]+/)
        if (n < 3) next
        from_ip = a[n]

        to_part = ""
        for (i = 1; i <= n - 2; i++) {
          if (a[i] == "ALLOW" || a[i] == "DENY" || a[i] == "LIMIT") break
          to_part = (to_part == "" ? a[i] : to_part " " a[i])
        }

        if (from_ip != tip) next
        if (tport != "" && index(to_part, tport) == 0) next

        print rnum
      }' | sort -nr)

    if [[ "${#rule_nums[@]}" -eq 0 ]]; then
      warn "未找到匹配 IP [${ip}] ${target_port:+端口 [${target_port}] }的白名单规则。"
      continue
    fi

    log "找到 ${#rule_nums[@]} 条规则，开始删除..."
    for num in "${rule_nums[@]}"; do
      log "删除 UFW 规则 #${num}"
      run ufw --force delete "${num}" >/dev/null
    done
    log "已成功删除 ${ip} 对应的白名单规则。"
  done
}

cmd_list_ip() {
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    have_cmd ufw || die "ufw 未安装"
  fi
  echo "=== 当前 UFW 白名单 IP 规则 ==="
  printf "%-6s  %-22s  %-28s  %s\n" "规则号" "目标端口/协议" "来源 IP/网段" "备注"
  printf "%-6s  %-22s  %-28s  %s\n" "------" "-------------" "------------" "----"
  local count=0
  while IFS=$'\t' read -r rnum to_part from_ip comm; do
    [[ -n "${rnum}" ]] || continue
    printf "[%-4s]  %-22s  %-28s  %s\n" "${rnum}" "${to_part}" "${from_ip}" "${comm}"
    count=$((count + 1))
  done < <(ufw status numbered 2>/dev/null | awk \
    -v cpfx="${WHITELIST_COMMENT}" \
    -v bpfx="${BOOTSTRAP_COMMENT}" '
    {
      line = $0
      if (!match(line, /\[[[:space:]]*([0-9]+)\]/)) next
      rnum = substr(line, RSTART, RLENGTH)
      gsub(/[^0-9]/, "", rnum)

      comm = ""
      if (match(line, /#[[:space:]]*.*/)) {
        comm = substr(line, RSTART + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", comm)
        line = substr(line, 1, RSTART - 1)
      }

      if (index(comm, cpfx) != 1 && index(comm, bpfx) != 1) next

      gsub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
      gsub(/[[:space:]]+$/, "", line)

      n = split(line, a, /[[:space:]]+/)
      if (n < 3) next
      from_ip = a[n]

      to_part = ""
      for (i = 1; i <= n - 2; i++) {
        if (a[i] == "ALLOW" || a[i] == "DENY" || a[i] == "LIMIT") break
        to_part = (to_part == "" ? a[i] : to_part " " a[i])
      }

      print rnum "\t" to_part "\t" from_ip "\t" comm
    }')

  echo
  echo "共计 ${count} 条白名单规则。"
}

enable_services() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "将启用 ${FWKNOP_UNIT} 与 UFW"
    return 0
  fi

  systemctl enable "${FWKNOP_UNIT}"
  systemctl restart "${FWKNOP_UNIT}"
  systemctl is-active --quiet "${FWKNOP_UNIT}" || die "${FWKNOP_UNIT} 启动失败，见: journalctl -u ${FWKNOP_UNIT} -e"

  "${PREFIX}/sbin/cf-ufw-update"

  if [[ "${ENABLE_UFW}" -eq 1 ]]; then
    ufw --force enable
  else
    warn "已按要求跳过 ufw enable，规则已写入但防火墙可能尚未生效。"
  fi
}

print_summary() {
  cat <<EOF

======== 安装完成 ========
UFW: 默认拒绝入站；Cloudflare -> TCP ${CF_PORTS}；其余端口需 fwknop 敲门
fwknopd: 监听 $(default_iface) UDP/${SPA_UDP_PORT}（UFW 不放行，端口保持关闭）
SPA 可请求打开: ${SPA_PORTS} ，时长 ${FW_ACCESS_TIMEOUT}s
客户端配置已写入: ${KEY_FILE}

客户端（需安装 fwknop）:

  # 把 ${KEY_FILE} 合并进笔记本上的 ~/.fwknoprc 后:
  fwknop -n ${SCRIPT_NAME}
  ssh USER@SERVER

  # 或一次性命令（把密钥换成 ${KEY_FILE} 里的值）:
  fwknop -A ${SPA_PORTS%%,*} -R -D SERVER --use-hmac \\
    --key-base64 'KEY' --hmac-key-base64 'HMAC'

日常维护:
  ${PREFIX}/sbin/cf-ufw-update          # 立刻刷新 Cloudflare IP
  systemctl status cf-ufw-update.timer  # 每日自动刷新
  $0 status
  $0 print-client

安全提示:
  - 用 'ufw status numbered' 找到 comment=${BOOTSTRAP_COMMENT} 的 SSH 应急规则，敲门验证后删掉
  - 不要 ufw allow ${SPA_UDP_PORT}/udp
  - 密钥文件权限应为 600，不要提交到 git
EOF
}

cmd_status() {
  echo "=== UFW ==="
  ufw status verbose || true
  echo
  echo "=== Cloudflare 规则条数 ==="
  ufw status | grep -c "# ${UFW_COMMENT}" || true
  echo
  cmd_list_ip
  echo
  detect_fwknop_unit
  echo "=== ${FWKNOP_UNIT} ==="
  systemctl status "${FWKNOP_UNIT}" --no-pager -l || true
  echo
  echo "=== 最近 fwknopd 日志 ==="
  journalctl -u "${FWKNOP_UNIT}" -n 20 --no-pager || true
}

cmd_print_client() {
  if [[ -f "${KEY_FILE}" ]]; then
    cat "${KEY_FILE}"
  elif [[ -f "/etc/fwknop/${SCRIPT_NAME}.keys" ]]; then
    cat "/etc/fwknop/${SCRIPT_NAME}.keys"
  else
    die "找不到客户端密钥，请先运行: $0 install"
  fi
}

cmd_uninstall() {
  need_root
  confirm "将删除 Cloudflare/fwknop 辅助规则与文件，但不会 disable UFW。继续？" || exit 1
  if have_cmd systemctl; then
    detect_fwknop_unit
    run systemctl disable --now cf-ufw-update.timer 2>/dev/null || true
    run systemctl stop "${FWKNOP_UNIT}" 2>/dev/null || true
  fi
  if have_cmd ufw; then
    load_conf
    ufw_delete_by_comment "${UFW_COMMENT}"
    ufw_delete_by_comment "${BOOTSTRAP_COMMENT}"
    ufw_delete_by_comment "${FWKNOP_COMMENT}"
    ufw_delete_by_comment "${WHITELIST_COMMENT}"
  fi
  run rm -f /etc/systemd/system/cf-ufw-update.service \
            /etc/systemd/system/cf-ufw-update.timer \
            "${PREFIX}/sbin/fwknop-ufw-open" \
            "${PREFIX}/sbin/fwknop-ufw-close" \
            "${PREFIX}/sbin/cf-ufw-update"
  run rm -rf "${CONF_DIR}"
  have_cmd systemctl && run systemctl daemon-reload || true
  log "已卸载辅助组件。UFW 仍保持当前启用状态；fwknop 软件包未 apt remove。"
  log "如需恢复旧 access.conf，见 ${KEY_BACKUP_DIR}"
}

cmd_install() {
  need_root
  validate_ports_csv "${CF_PORTS}"
  validate_spa_ports "${SPA_PORTS}"
  [[ "${FW_ACCESS_TIMEOUT}" =~ ^[0-9]+$ ]] || die "--timeout 必须是秒数"
  have_cmd ip || die "需要 iproute2"

  cat <<EOF
即将配置:
  Cloudflare TCP ${CF_PORTS} 放行（自动拉取官方 CIDR，每日刷新）
  UFW 默认拒绝其他入站
  fwknop SPA 可打开: ${SPA_PORTS}（${FW_ACCESS_TIMEOUT}s）
  网卡: $(default_iface || echo 未知)
  UFW reset: $([[ ${RESET_UFW} -eq 1 ]] && echo 是，将清空现有规则 || echo 否，保留现有规则)
EOF
  confirm "确认安装？" || exit 1

  install_packages
  detect_fwknop_unit
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    have_cmd ufw || die "ufw 未安装"
    have_cmd fwknopd || die "fwknopd 未安装"
    have_cmd fwknop || die "fwknop 客户端未安装（用于 --key-gen）"
  fi

  write_conf
  write_helpers
  write_systemd_timer
  generate_keys
  write_fwknop_access
  configure_fwknopd
  write_client_rc
  configure_ufw_policy
  apply_bootstrap_ssh
  apply_initial_whitelist
  enable_services
  print_summary
}

main() {
  parse_args "$@"
  case "${CMD}" in
    help|-h|--help) usage ;;
    install) cmd_install ;;
    update-cf) need_root; load_conf; [[ -x "${PREFIX}/sbin/cf-ufw-update" ]] || die "尚未安装，请先 $0 install"; "${PREFIX}/sbin/cf-ufw-update" ;;
    status) cmd_status ;;
    print-client) cmd_print_client ;;
    uninstall) cmd_uninstall ;;
    allow-ip|add-ip|add-whitelist) cmd_allow_ip ;;
    del-ip|delete-ip|remove-ip|whitelist-del) cmd_del_ip ;;
    list-ip|list-whitelist|whitelist) cmd_list_ip ;;
  esac
}

main "$@"
