#!/usr/bin/env bash
# ghost-origin — UFW default-deny + Cloudflare 80/443 + fwknop SPA
#
# Incoming policy:
#   - allow Cloudflare IPv4/IPv6 -> TCP 80,443
#   - allow established/related (UFW default)
#   - deny everything else
#   - fwknop SPA temporarily opens requested ports (default tcp/22) via UFW
#
# Default UDP mode supports distribution builds without libpcap and requires
# an IPv4 UDP SPA transport rule. Optional pcap mode keeps that port dropped.
set -euo pipefail

readonly SCRIPT_NAME="ghost-origin"
readonly SCRIPT_VERSION="1.4.0"
readonly SCRIPT_UPDATED_AT="2026-09-17"
readonly PREFIX="/usr/local"
readonly CONF_DIR="/etc/ghost-origin"
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
readonly KEY_BACKUP_DIR="/root/ghost-origin-backup"

CF_PORTS="${CF_PORTS:-80,443}"
SPA_PORTS="${SPA_PORTS:-tcp/22}"
SSH_PORT="${SSH_PORT:-}"
FW_ACCESS_TIMEOUT="${FW_ACCESS_TIMEOUT:-60}"
SPA_UDP_PORT="${SPA_UDP_PORT:-62201}"
SPA_MODE="${SPA_MODE:-udp}"
ALLOW_SSH_FROM="${ALLOW_SSH_FROM:-}"
WHITELIST_IPS="${WHITELIST_IPS:-}"
BOOTSTRAP_SSH="${BOOTSTRAP_SSH:-auto}"
MANAGE_DOCKER="${MANAGE_DOCKER:-auto}"
CLI_SPECIFIED_ALLOW_SSH_FROM=0
CLI_SPECIFIED_SSH_PORT=0
if [[ -n "${ALLOW_SSH_FROM}" ]]; then
  CLI_SPECIFIED_ALLOW_SSH_FROM=1
fi
if [[ -n "${SSH_PORT}" ]]; then
  CLI_SPECIFIED_SSH_PORT=1
fi
ASSUME_YES=0
DRY_RUN=0
SKIP_APT=0
FORCE_KEYS=0
ENABLE_UFW=1
ENABLE_IPV6=1
RESET_UFW=1
CMD="help"
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
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    cat <<EOF >&2
======================================================================
 [错误] 权限不足：本脚本涉及防火墙规则 (UFW) 与系统服务配置，必须以 root 权限运行！
======================================================================
 当前运行身份: UID=$(id -u) ($(id -un 2>/dev/null || echo "non-root"))

 运行建议：
   1) 使用 sudo 运行：
      sudo $0 ${*:-${CMD}}
   2) 或者直接切换到 root 环境（推荐，之后无需每次加 sudo）：
      sudo -i
      $0 ${*:-${CMD}}
======================================================================
EOF
    exit 1
  fi
}

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} (updated: ${SCRIPT_UPDATED_AT})

用法:
  $0                               显示帮助（不安装，无需 root）
  $0 install [选项]                 安装并配置 ufw + fwknop
  $0 allow-ip <IP[/CIDR]> [选项]     添加白名单 IP（放行访问，免敲门）
  $0 del-ip <IP[/CIDR]> [选项]       删除白名单 IP 规则
  $0 list-ip                        查看当前白名单 IP 列表
  $0 update                         从 GitHub main 升级命令脚本，不修改防火墙配置
  $0 --version                      查看版本号与更新日期
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
  --spa-mode udp|pcap        接收模式（默认 udp：放行 IPv4 UDP SPA 端口）
  --ssh-port 22              用于防锁死的 SSH 端口（未指定时自动探测监听端口，默认 22）
  --timeout 60               SPA 打开时长（秒）
  --allow-ssh-from IP        放行该 IP 直连 SSH（未指定时自动探测当前连接客户端并询问）
  --whitelist-ips "IP1,IP2"  安装时初始添加的白名单 IP 列表
  --bootstrap-ssh            从当前 SSH 来源 IP 临时放行 SSH（默认：检测到 SSH 则开启）
  --no-bootstrap-ssh         不添加 SSH 应急规则（可能把自己锁在门外）
  --no-ufw-enable            只写规则，不执行 ufw --force enable
  --keep-ufw-rules           不执行 ufw reset（保留现有规则，仍会改默认策略）
  --no-ipv6                  不处理 IPv6 / 不放行 Cloudflare IPv6
  --docker                   对 Docker 容器发布的 80/443 也仅放行 Cloudflare（DOCKER-USER 链）
  --no-docker                不管理 Docker（默认 auto：检测到 Docker 则询问）
  --skip-apt                 跳过 apt 安装（检测到已有敲门软件时拒绝继续）
  --force-keys               重新生成 fwknop 密钥（覆盖旧密钥）
  --yes, -y                  非交互
  --dry-run                  只打印将执行的命令
  -h, --help                 帮助

已有 knockd/fwknop 时需在终端单独确认移除/升级，--yes 不跳过。
拒绝操作会取消安装；APT remove 保留 knockd 配置，不执行 purge。
环境变量可覆盖同名默认值: CF_PORTS SPA_PORTS SSH_PORT FW_ACCESS_TIMEOUT ALLOW_SSH_FROM WHITELIST_IPS
EOF
}

parse_args() {
  # Installation must always be explicitly requested, including as root.
  CMD="help"
  if [[ "${#}" -gt 0 && "$1" != -* ]]; then
    CMD="$1"
    shift
  fi
  case "${CMD}" in
    install|update|version|update-cf|status|print-client|uninstall|allow-ip|add-ip|add-whitelist|del-ip|delete-ip|remove-ip|whitelist-del|list-ip|list-whitelist|whitelist|help|-h|--help) ;;
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
      --spa-mode) SPA_MODE="${2:?}"; shift 2 ;;
      --ssh-port) SSH_PORT="${2:?}"; CLI_SPECIFIED_SSH_PORT=1; shift 2 ;;
      --timeout) FW_ACCESS_TIMEOUT="${2:?}"; shift 2 ;;
      --allow-ssh-from) ALLOW_SSH_FROM="${2:?}"; CLI_SPECIFIED_ALLOW_SSH_FROM=1; shift 2 ;;
      --bootstrap-ssh) BOOTSTRAP_SSH="yes"; shift ;;
      --no-bootstrap-ssh) BOOTSTRAP_SSH="no"; shift ;;
      --no-ufw-enable) ENABLE_UFW=0; shift ;;
      --keep-ufw-rules) RESET_UFW=0; shift ;;
      --no-ipv6) ENABLE_IPV6=0; shift ;;
      --docker) MANAGE_DOCKER="yes"; shift ;;
      --no-docker) MANAGE_DOCKER="no"; shift ;;
      --skip-apt) SKIP_APT=1; shift ;;
      --force-keys) FORCE_KEYS=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -v|--version) printf '%s %s (updated: %s)\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${SCRIPT_UPDATED_AT}"; exit 0 ;;
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

detect_sshd_port() {
  local port=""
  if have_cmd ss; then
    port="$(ss -tlnp 2>/dev/null | awk '
      $1 ~ /^LISTEN/ {
        addr = $4
        sub(/.*:/, "", addr)
        if (addr ~ /^[0-9]+$/ && ($0 ~ /sshd/ || addr == "22")) {
          print addr
          exit
        }
      }')"
  fi
  if [[ -z "${port}" ]] && have_cmd sshd; then
    port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
  fi
  if [[ -z "${port}" && -f /etc/ssh/sshd_config ]]; then
    port="$(grep -Eh "^[[:space:]]*Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | tail -n 1)"
  fi
  printf '%s\n' "${port:-22}"
}

current_ssh_ip() {
  local port="${1:-${SSH_PORT:-22}}"
  local ip=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="${SSH_CONNECTION%% *}"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    ip="${SSH_CLIENT%% *}"
  fi
  if [[ -z "${ip}" ]] && have_cmd who; then
    ip="$(who -m 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\([0-9a-fA-F.:]+\)$/) {gsub(/[()]/,"",$i); print $i; exit}}')"
  fi
  if [[ -z "${ip}" ]] && have_cmd ss; then
    ip="$(ss -tn state established "( sport = :${port} )" 2>/dev/null | awk '
      $1 ~ /^ESTAB/ {
        peer = $5
        sub(/:[0-9]+$/, "", peer)
        gsub(/^[\[]|[\]]$/, "", peer)
        if (peer != "" && peer != "127.0.0.1" && peer != "::1") {
          print peer
          exit
        }
      }')"
  fi
  printf '%s\n' "${ip}"
}

get_server_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if [[ -z "${ip}" || "${ip}" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.) ]]; then
    local ext_ip=""
    ext_ip="$(curl -fsSL4 --max-time 3 https://api.ipify.org 2>/dev/null || curl -fsSL4 --max-time 3 https://ifconfig.me 2>/dev/null || true)"
    if [[ -n "${ext_ip}" && "${ext_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      ip="${ext_ip}"
    fi
  fi
  printf '%s\n' "${ip:-YOUR_SERVER_IP}"
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

confirm_yes_default() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  local ans=""
  if [[ -t 0 ]]; then
    read -r -p "${prompt} [Y/n] " ans
  elif [[ -r /dev/tty ]]; then
    read -r -p "${prompt} [Y/n] " ans < /dev/tty
  else
    return 0
  fi
  [[ -z "${ans}" || "${ans}" == "y" || "${ans}" == "Y" ]]
}

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  local ans=""
  if [[ -t 0 ]]; then
    read -r -p "${prompt} [y/N] " ans
  elif [[ -r /dev/tty ]]; then
    read -r -p "${prompt} [y/N] " ans < /dev/tty
  else
    warn "非交互模式且未指定 -y/--yes，跳过交互。如需静默安装请加 --yes"
    return 1
  fi
  [[ "${ans}" == "y" || "${ans}" == "Y" ]]
}

backup_file() {
  local src="$1"
  [[ -f "${src}" ]] || return 0
  run mkdir -p "${KEY_BACKUP_DIR}"
  run cp -a "${src}" "${KEY_BACKUP_DIR}/$(basename "${src}").$(date +%Y%m%d%H%M%S)"
}

# Preflight is read-only until every decision and the installation confirmation
# have been accepted. Never treat --yes as consent to replace existing tools.
REMOVE_KNOCKD=0
FWKNOP_UPGRADE_PACKAGES=()

package_installed() {
  local state
  state="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || return 1
  [[ "${state}" == "install ok installed" ]]
}

service_present() {
  local state
  state="$(systemctl show "$1" --property=LoadState --value 2>/dev/null)" || return 1
  [[ -n "${state}" && "${state}" != "not-found" ]]
}

confirm_existing_tool() {
  # Use the controlling terminal: stdin may contain the script from curl.
  local answer=""
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: 实际安装时必须确认：$1"
    return 0
  fi
  if ! { printf '%s [y/N] ' "$1" > /dev/tty && read -r answer < /dev/tty; } 2>/dev/null; then
    warn "现有软件需要单独确认（--yes 不跳过）；请在交互终端重新运行。"
    return 1
  fi
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

preflight_existing_tools() {
  local knockd_found=0 fwknop_found=0 package
  REMOVE_KNOCKD=0
  FWKNOP_UPGRADE_PACKAGES=()
  if package_installed knockd || have_cmd knockd || service_present knockd.service; then
    knockd_found=1
  fi
  for package in fwknop-server fwknop-client; do
    if package_installed "${package}"; then
      FWKNOP_UPGRADE_PACKAGES+=("${package}")
      fwknop_found=1
    fi
  done
  if have_cmd fwknop || have_cmd fwknopd || service_present fwknop-server.service || service_present fwknopd.service; then
    fwknop_found=1
  fi
  if (( knockd_found || fwknop_found )); then
    [[ "${SKIP_APT}" -eq 0 ]] || die "检测到已有敲门软件；--skip-apt 无法完成移除/升级，请去掉该选项后重试。"
  fi
  if (( knockd_found )); then
    package_installed knockd || die "检测到非 APT 管理的 knockd，请先手动处理其程序和服务；不会自动删除未知文件。"
    confirm_existing_tool "检测到 knockd。是否备份配置并移除 knockd（旧敲门方式将失效）？" || die "未同意移除 knockd，安装已取消，未修改系统。"
    REMOVE_KNOCKD=1
  fi
  if (( fwknop_found )); then
    (( ${#FWKNOP_UPGRADE_PACKAGES[@]} > 0 )) || die "检测到非 APT 管理的 fwknop，请先手动处理后重试。"
    confirm_existing_tool "检测到 fwknop。是否备份配置、升级至 APT 候选版本并继续应用本项目配置（可能重启服务）？" || die "未同意升级 fwknop，安装已取消，未修改系统。"
  fi
}

install_packages() {
  [[ "${SKIP_APT}" -eq 1 ]] && return 0
  have_cmd apt-get || die "当前仅支持 Debian/Ubuntu（需要 apt-get）"
  export DEBIAN_FRONTEND=noninteractive
  log "安装 ufw / fwknop-server / fwknop-client ..."
  run apt-get update -y
  if (( ${#FWKNOP_UPGRADE_PACKAGES[@]} > 0 )); then
    backup_file "${ACCESS_CONF}"
    backup_file "${FWKNOPD_CONF}"
    run apt-get install -y --only-upgrade "${FWKNOP_UPGRADE_PACKAGES[@]}"
  fi
  if [[ "${REMOVE_KNOCKD}" -eq 1 ]]; then
    backup_file /etc/knockd.conf
    backup_file /etc/default/knockd
    if service_present knockd.service; then
      run systemctl disable --now knockd.service
    fi
    # remove, not purge: retain configuration; do not autoremove dependencies.
    run apt-get remove -y knockd
  fi
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
SPA_MODE=${SPA_MODE}
ENABLE_IPV6=${ENABLE_IPV6}
MANAGE_DOCKER=${MANAGE_DOCKER}
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
case "${PROTO}" in
  6|tcp) PROTO="tcp" ;;
  17|udp) PROTO="udp" ;;
  *) echo "不支持的协议: ${PROTO}" >&2; exit 1 ;;
esac
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
case "${PROTO}" in
  6|tcp) PROTO="tcp" ;;
  17|udp) PROTO="udp" ;;
  *) exit 0 ;;
esac
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
CONF_FILE="/etc/ghost-origin/config"
[[ ! -f "${CONF_FILE}" && -f "/etc/cf-ufw-quickstart/config" ]] && CONF_FILE="/etc/cf-ufw-quickstart/config"
[[ -f "${CONF_FILE}" ]] && source "${CONF_FILE}"

CF_PORTS="${CF_PORTS:-80,443}"
ENABLE_IPV6="${ENABLE_IPV6:-1}"
MANAGE_DOCKER="${MANAGE_DOCKER:-0}"
DOCKER_CHAIN="GHOST_ORIGIN_DOCKER"
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

docker_remove_jumps() {
  local ipt="$1" num
  while num="$("${ipt}" -L DOCKER-USER --line-numbers -n 2>/dev/null | awk -v c="${DOCKER_CHAIN}" '$0 ~ c {print $1; exit}')" && [[ -n "${num}" ]]; do
    "${ipt}" -D DOCKER-USER "${num}" >/dev/null 2>&1 || break
  done
}

docker_sync_family() {
  # $1=iptables|ip6tables  $2=cidr file  $3=ingress iface
  local ipt="$1" cidr_file="$2" iface="$3" c
  command -v "${ipt}" >/dev/null 2>&1 || return 0
  "${ipt}" -L DOCKER-USER -n >/dev/null 2>&1 || return 0
  "${ipt}" -N "${DOCKER_CHAIN}" 2>/dev/null || true
  "${ipt}" -F "${DOCKER_CHAIN}"
  while IFS= read -r c; do
    [[ -n "${c}" ]] || continue
    "${ipt}" -A "${DOCKER_CHAIN}" -s "${c}" -j RETURN
  done < "${cidr_file}"
  # Anything reaching this chain is NEW inbound to the published web ports.
  "${ipt}" -A "${DOCKER_CHAIN}" -j DROP
  docker_remove_jumps "${ipt}"
  # -i <iface> so only internet-facing NEW web traffic is filtered; container
  # egress and inter-container traffic enter via bridge interfaces and are untouched.
  "${ipt}" -I DOCKER-USER -i "${iface}" -p tcp -m multiport --dports "${CF_PORTS}" \
    -m conntrack --ctstate NEW -j "${DOCKER_CHAIN}"
}

sync_docker() {
  [[ "${MANAGE_DOCKER}" == "1" ]] || return 0
  local iface
  iface="$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  if [[ -z "${iface}" ]]; then
    log "无法确定默认网卡，跳过 Docker 同步"
    return 0
  fi
  if ! command -v iptables >/dev/null 2>&1 || ! iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    log "无 DOCKER-USER 链（Docker 未安装或未启用 iptables），跳过 Docker 同步"
    return 0
  fi
  printf '%s\n' "${clean_v4[@]}" > "${tmp}/v4docker"
  docker_sync_family iptables "${tmp}/v4docker" "${iface}"
  if [[ "${ENABLE_IPV6}" == "1" || "${ENABLE_IPV6}" -eq 1 ]]; then
    printf '%s\n' "${clean_v6[@]}" > "${tmp}/v6docker"
    docker_sync_family ip6tables "${tmp}/v6docker" "${iface}"
  fi
  log "Docker DOCKER-USER 已同步：仅允许 Cloudflare 访问容器端口 ${CF_PORTS}（入口网卡 ${iface}）"
  logger -t cf-ufw-update "docker chain synced for ${CF_PORTS} on ${iface}"
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

sync_docker
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

validate_key_file() {
  python3 - "$1" <<'PY'
import base64
import sys
try:
    values = {}
    with open(sys.argv[1], encoding='ascii') as stream:
        for line in stream:
            fields = line.split()
            if fields:
                fields[0] = fields[0].rstrip(':')
            if fields and fields[0] in ('KEY_BASE64', 'HMAC_KEY_BASE64'):
                if len(fields) != 2 or fields[0] in values:
                    raise ValueError('invalid key entry')
                values[fields[0]] = base64.b64decode(fields[1], validate=True)
    if not 1 <= len(values['KEY_BASE64']) <= 32:
        raise ValueError('invalid encryption key length')
    if not 1 <= len(values['HMAC_KEY_BASE64']) <= 128:
        raise ValueError('invalid HMAC key length')
except (OSError, ValueError, KeyError, UnicodeError):
    sys.exit(1)
PY
}

# Stage and validate before publishing; a failure must not replace existing keys.
generate_key_file() (
  local destination="$1" stage_dir
  umask 077
  stage_dir="$(mktemp -d /etc/fwknop/.ghost-origin-keys.XXXXXXXX)"
  trap 'rm -rf -- "${stage_dir}"' EXIT
  fwknop --key-gen --use-hmac --key-len 32 --hmac-key-len 64 \
    --key-gen-file "${stage_dir}/keys"
  validate_key_file "${stage_dir}/keys" || die "新生成的密钥无效，未替换已有密钥"
  chmod 600 "${stage_dir}/keys"
  mv -fT -- "${stage_dir}/keys" "${destination}"
)

generate_keys() {
  local gen_file="/etc/fwknop/${SCRIPT_NAME}.keys"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    KEY_BASE64="DRYRUN_KEY"
    HMAC_KEY_BASE64="DRYRUN_HMAC"
    log "dry-run: 跳过密钥生成"
    return 0
  fi
  if [[ -f "${gen_file}" && "${FORCE_KEYS}" -eq 0 ]]; then
    validate_key_file "${gen_file}" || die "已有密钥文件无效：${gen_file}。请先备份，再使用 --force-keys 重新生成；客户端也需要更新密钥。"
    log "复用已有密钥 ${gen_file}（需要重新生成请加 --force-keys）"
  else
    backup_file "${gen_file}"
    log "生成 fwknop HMAC 密钥 ..."
    generate_key_file "${gen_file}"
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
CMD_CYCLE_TIMER             ${FW_ACCESS_TIMEOUT}
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
  # Remove active duplicates, not commented examples, then append exactly once.
  sed -i -E "/^[[:space:]]*${key}[[:space:]]/d" "${file}"
  printf '%s    %s;\n' "${key}" "${val}" >> "${file}"
}

configure_fwknopd() {
  backup_file "${FWKNOPD_CONF}"
  local iface
  iface="$(default_iface)"
  [[ -n "${iface}" ]] || die "无法检测默认路由网卡，请手动设置 ${FWKNOPD_CONF} 中的 PCAP_INTF"
  log "fwknopd 接收模式: ${SPA_MODE}；网卡: ${iface}；SPA UDP/${SPA_UDP_PORT}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi

  set_fwknopd_var "PCAP_INTF" "${iface}"
  set_fwknopd_var "ENABLE_PCAP_PROMISC" "N"
  set_fwknopd_var "PCAP_FILTER" "udp port ${SPA_UDP_PORT}"
  # ENABLE_IPT_INPUT does not exist in fwknop 2.6.10. Command-cycle stanzas
  # bypass native firewall operations; no invented disable-input setting needed.
  sed -i -E '/^[[:space:]]*(ENABLE_IPT_INPUT|ENABLE_NFQ_CAPTURE)[[:space:]]/d' "${FWKNOPD_CONF}"
  set_fwknopd_var "ENABLE_IPT_OUTPUT" "N"
  set_fwknopd_var "ENABLE_IPT_FORWARDING" "N"
  set_fwknopd_var "UDPSERV_PORT" "${SPA_UDP_PORT}"
  if [[ "${SPA_MODE}" == "udp" ]]; then
    set_fwknopd_var "ENABLE_UDP_SERVER" "Y"
  else
    # Leave unset so a no-pcap build reports its forced UDP fallback at parse time.
    sed -i -E '/^[[:space:]]*ENABLE_UDP_SERVER[[:space:]]/d' "${FWKNOPD_CONF}"
  fi
}

validate_fwknop_config() (
  [[ "${DRY_RUN}" -eq 0 ]] || { log "DRY-RUN: fwknopd --exit-parse-config"; return 0; }
  local report
  umask 077
  report="$(mktemp)"
  trap 'rm -f -- "${report}"' EXIT
  if ! LC_ALL=C fwknopd -c "${FWKNOPD_CONF}" -a "${ACCESS_CONF}" --exit-parse-config >"${report}" 2>&1; then
    cat "${report}" >&2
    die "fwknop 配置解析失败，未重置 UFW。"
  fi
  if grep -qi 'unknown configuration parameter' "${report}"; then
    cat "${report}" >&2
    die "fwknop 配置含未知参数，未重置 UFW。"
  fi
  if [[ "${SPA_MODE}" == "pcap" ]] && grep -qi 'forcing UDP server mode' "${report}"; then
    die "此 fwknopd 未编译 libpcap，不能使用 pcap 模式。请选 --spa-mode udp 或安装支持 libpcap 的版本；未重置 UFW。"
  fi
  log "fwknop 配置解析通过。"
)

start_fwknop_service() {
  [[ "${DRY_RUN}" -eq 0 ]] || { log "DRY-RUN: 在重置 UFW 前验证 fwknop 服务启动"; return 0; }
  systemctl reset-failed "${FWKNOP_UNIT}" || true
  if ! systemctl restart "${FWKNOP_UNIT}" || ! systemctl is-active --quiet "${FWKNOP_UNIT}"; then
    die "${FWKNOP_UNIT} 启动失败，未重置 UFW。请查看 journalctl -u ${FWKNOP_UNIT} -n 50 --no-pager"
  fi
  systemctl enable "${FWKNOP_UNIT}"
}

write_client_rc() {
  local server_ip
  server_ip="$(get_server_ip)"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "将写入客户端配置 ${KEY_FILE}"
    return 0
  fi
  cat > "${KEY_FILE}" <<EOF
# fwknop client stanza — copy to ~/.fwknoprc on your laptop
# 先敲门再 SSH:  fwknop -n ${server_ip} && ssh user@${server_ip}
#
# macOS 说明:
#   如果提示 'Use --wget-cmd <path> to specify path to the wget command':
#   方法 A (免装 wget): 直接用 curl 传本地公网 IP 敲门:
#       fwknop -n ${server_ip} -a \$(curl -s4 ifconfig.me)
#   方法 B (安装 wget): 执行 'brew install wget'，并在下方配置中添加:
#       WGET_CMD    /opt/homebrew/bin/wget   # Apple Silicon Mac
#       # 或 WGET_CMD /usr/local/bin/wget    # Intel Mac

[${server_ip}]
SPA_SERVER          ${server_ip}
SPA_SERVER_PORT     ${SPA_UDP_PORT}
ACCESS              ${SPA_PORTS%%,*}
KEY_BASE64          ${KEY_BASE64}
HMAC_KEY_BASE64     ${HMAC_KEY_BASE64}
USE_HMAC            Y
RESOLVE_IP_HTTPS    Y
# WGET_CMD          /opt/homebrew/bin/wget
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
  if [[ "${SPA_MODE}" == "udp" ]]; then
    warn "UDP 模式：放行 IPv4 UDP/${SPA_UDP_PORT} 作为 SPA 传输入口，SSH 仍需认证授权。"
    ufw allow proto udp from 0.0.0.0/0 to any port "${SPA_UDP_PORT}" comment ghost-origin-spa
  fi
}

preflight_ssh_access() {
  [[ "${BOOTSTRAP_SSH}" == "auto" || "${BOOTSTRAP_SSH}" == "yes" || "${BOOTSTRAP_SSH}" == "no" ]] || die "BOOTSTRAP_SSH 必须是 auto/yes/no"

  # 1. 自动探测或验证 SSH_PORT
  if [[ "${CLI_SPECIFIED_SSH_PORT}" -eq 0 || -z "${SSH_PORT}" ]]; then
    local detected_port
    detected_port="$(detect_sshd_port)"
    SSH_PORT="${detected_port:-22}"
    log "自动探测到 SSH 服务监听端口: ${SSH_PORT}"
  fi
  [[ "${SSH_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || die "SSH_PORT 端口号无效: ${SSH_PORT}"

  # 2. 如果用户显式传了 --no-bootstrap-ssh
  if [[ "${BOOTSTRAP_SSH}" == "no" ]]; then
    ALLOW_SSH_FROM=""
    warn "已配置跳过 SSH 应急规则（--no-bootstrap-ssh）。新 SSH 连接需先通过 fwknop 敲门。"
    return 0
  fi

  # 3. 如果用户显式传了 --allow-ssh-from
  if [[ "${CLI_SPECIFIED_ALLOW_SSH_FROM}" -eq 1 && -n "${ALLOW_SSH_FROM}" ]]; then
    is_ipv4 "${ALLOW_SSH_FROM}" || is_ipv6 "${ALLOW_SSH_FROM}" || die "--allow-ssh-from 不是合法 IP: ${ALLOW_SSH_FROM}"
    BOOTSTRAP_SSH="yes"
    log "使用指定 SSH 应急放行 IP: ${ALLOW_SSH_FROM} -> TCP/${SSH_PORT}"
    return 0
  fi

  # 4. 未指定时自动探测当前 SSH 客户端 IP
  local detected_client_ip
  detected_client_ip="$(current_ssh_ip "${SSH_PORT}")"

  if [[ -n "${detected_client_ip}" ]]; then
    log "自动探测到当前 SSH 客户端连接: IP [${detected_client_ip}]，端口 [${SSH_PORT}]"
    if confirm_yes_default "是否添加防锁死应急规则（允许 ${detected_client_ip} -> TCP/${SSH_PORT}）？"; then
      ALLOW_SSH_FROM="${detected_client_ip}"
      BOOTSTRAP_SSH="yes"
      log "已确认添加防锁死应急规则: 允许 ${ALLOW_SSH_FROM} -> TCP/${SSH_PORT}"
    else
      ALLOW_SSH_FROM=""
      BOOTSTRAP_SSH="no"
      warn "用户选择不添加 SSH 应急规则。安装完成后新 SSH 连接必须先通过 fwknop 敲门。"
    fi
  else
    # 未探测到客户端 IP
    if [[ -t 0 || -r /dev/tty ]] && [[ "${ASSUME_YES}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
      warn "未自动探测到当前 SSH 客户端 IP（SSH 监听端口: ${SSH_PORT}）。"
      local ans="" manual_ip=""
      printf "是否手动输入客户端公网 IP 以添加防锁死应急规则？ [y/N] " >/dev/tty && read -r ans < /dev/tty || ans="n"
      if [[ "${ans}" == "y" || "${ans}" == "Y" ]]; then
        printf "请输入您的客户端公网 IP: " >/dev/tty && read -r manual_ip < /dev/tty || manual_ip=""
        manual_ip="${manual_ip// /}"
        if is_ipv4 "${manual_ip}" || is_ipv6 "${manual_ip}"; then
          ALLOW_SSH_FROM="${manual_ip}"
          BOOTSTRAP_SSH="yes"
          log "已配置 SSH 应急规则: 允许 ${ALLOW_SSH_FROM} -> TCP/${SSH_PORT}"
        else
          die "输入的 IP 格式无效: ${manual_ip}"
        fi
      else
        ALLOW_SSH_FROM=""
        BOOTSTRAP_SSH="no"
        warn "未配置 SSH 应急规则。请确保安装完成后能通过 fwknop 敲门连接。"
      fi
    else
      ALLOW_SSH_FROM=""
      BOOTSTRAP_SSH="no"
      warn "未探测到当前 SSH 客户端 IP，跳过防锁死应急规则。新 SSH 连接需先通过 fwknop 敲门。"
    fi
  fi
}

apply_bootstrap_ssh() {
  if [[ "${BOOTSTRAP_SSH}" == "yes" && -n "${ALLOW_SSH_FROM}" ]]; then
    is_ipv4 "${ALLOW_SSH_FROM}" || is_ipv6 "${ALLOW_SSH_FROM}" || die "--allow-ssh-from 不是合法 IP: ${ALLOW_SSH_FROM}"
    log "应急放行 SSH: ${ALLOW_SSH_FROM} -> tcp/${SSH_PORT}"
    [[ "${DRY_RUN}" -eq 1 ]] && return 0
    ufw allow proto tcp from "${ALLOW_SSH_FROM}" to any port "${SSH_PORT}" comment "${BOOTSTRAP_COMMENT}"
  else
    warn "未添加 SSH 应急规则。启用 UFW 后，新 SSH 必须先 fwknop 敲门。"
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

  "${PREFIX}/sbin/cf-ufw-update"

  if [[ "${ENABLE_UFW}" -eq 1 ]]; then
    ufw --force enable
  else
    warn "已按要求跳过 ufw enable，规则已写入但防火墙可能尚未生效。"
  fi
}

print_summary() {
  local server_ip
  server_ip="$(get_server_ip)"
  cat <<EOF

======== 安装完成 ========
UFW: 默认拒绝入站；Cloudflare -> TCP ${CF_PORTS}；其余端口需 fwknop 敲门
fwknopd: ${SPA_MODE} 模式，SPA UDP/${SPA_UDP_PORT}（udp 模式显式放行 IPv4 SPA；pcap 模式不放行）
SPA 可请求打开: ${SPA_PORTS} ，时长 ${FW_ACCESS_TIMEOUT}s
客户端配置已写入: ${KEY_FILE}

客户端（需安装 fwknop）:

  # 把 ${KEY_FILE} 合并进笔记本上的 ~/.fwknoprc 后:
  fwknop -n ${server_ip}
  ssh USER@${server_ip}

  # 或一次性命令（把密钥换成 ${KEY_FILE} 里的值）:
  fwknop -A ${SPA_PORTS%%,*} -R -D ${server_ip} --use-hmac \\
    --key-base64 'KEY' --hmac-key-base64 'HMAC'

日常维护:
  ${PREFIX}/sbin/cf-ufw-update          # 立刻刷新 Cloudflare IP
  systemctl status cf-ufw-update.timer  # 每日自动刷新
  $0 status
  $0 print-client

安全提示:
  - 用 'ufw status numbered' 找到 comment=${BOOTSTRAP_COMMENT} 的 SSH 应急规则，敲门验证后删掉
  - udp 模式需要 IPv4 UDP/${SPA_UDP_PORT} 可达（包括云防火墙）；pcap 模式不需要放行 SPA 端口
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
  local server_ip
  server_ip="$(get_server_ip)"
  if [[ -f "${KEY_FILE}" ]]; then
    if [[ "${server_ip}" != "YOUR_SERVER_IP" ]]; then
      sed -i -E "s/^\\[(ghost-origin|cf-ufw-quickstart)\\]/[${server_ip}]/; s/fwknop -n (ghost-origin|cf-ufw-quickstart)/fwknop -n ${server_ip}/g; s/SPA_SERVER[[:space:]]+(YOUR_SERVER_IP|ghost-origin)/SPA_SERVER          ${server_ip}/g" "${KEY_FILE}"
    fi
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
    ufw_delete_by_comment ghost-origin-spa
  fi
  docker_cleanup
  run rm -f /etc/systemd/system/cf-ufw-update.service \
            /etc/systemd/system/cf-ufw-update.timer \
            "${PREFIX}/sbin/fwknop-ufw-open" \
            "${PREFIX}/sbin/fwknop-ufw-close" \
            "${PREFIX}/sbin/cf-ufw-update" \
            /usr/bin/ghost-origin
  run rm -rf "${CONF_DIR}"
  have_cmd systemctl && run systemctl daemon-reload || true
  log "已卸载辅助组件。UFW 仍保持当前启用状态；fwknop 软件包未 apt remove。"
  log "如需恢复旧 access.conf，见 ${KEY_BACKUP_DIR}"
}

# Install a complete executable, never a wrapper that depends on the checkout.
# curl | bash has no source file: fetch a complete copy before publishing it.
install_cli() (
  local source_file="${BASH_SOURCE[0]:-}" stage
  local destination="/usr/bin/ghost-origin"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: 安装独立命令到 ${destination}（root:root 0755）"
    return 0
  fi
  stage="$(mktemp /usr/bin/.ghost-origin.XXXXXXXX)"
  trap 'rm -f -- "${stage}"' EXIT
  if [[ "${1:-local}" != "remote" && -n "${source_file}" && -f "${source_file}" ]]; then
    cp -- "${source_file}" "${stage}"
  else
    log "从 GitHub main 下载最新脚本（HTTPS）。"
    curl --fail --silent --show-error --location --proto '=https' \
      --connect-timeout 15 --max-time 60 \
      https://raw.githubusercontent.com/taills/ghost-origin/main/ghost-origin.sh \
      -o "${stage}"
  fi
  [[ -s "${stage}" ]] || die "命令脚本为空，拒绝安装"
  bash -n "${stage}" || die "命令脚本语法检查失败"
  grep -q '^main "\$@"' "${stage}" || die "下载内容不是预期的安装脚本"
  chown root:root "${stage}"
  chmod 0755 "${stage}"
  # Atomic replacement also supports running `ghost-origin install` itself.
  mv -fT -- "${stage}" "${destination}"
  log "已安装 ${destination}；现在可以运行 ghost-origin status"
)

cmd_update() {
  log "当前版本: ${SCRIPT_VERSION} (${SCRIPT_UPDATED_AT})"
  log "仅替换 /usr/bin/ghost-origin；不重装依赖、不修改配置、密钥或 UFW 规则。"
  install_cli remote
}

docker_user_chain_present() {
  have_cmd iptables && iptables -L DOCKER-USER -n >/dev/null 2>&1
}

resolve_docker_choice() {
  case "${MANAGE_DOCKER}" in
    yes) MANAGE_DOCKER=1; return 0 ;;
    no)  MANAGE_DOCKER=0; return 0 ;;
  esac
  # auto
  if [[ "${DRY_RUN}" -eq 1 ]]; then MANAGE_DOCKER=0; return 0; fi
  if have_cmd docker && docker_user_chain_present; then
    if confirm_yes_default "检测到 Docker（DOCKER-USER 链）。Docker 发布端口会绕过 UFW；是否让容器的 ${CF_PORTS} 也仅放行 Cloudflare？"; then
      MANAGE_DOCKER=1
      log "已启用 Docker DOCKER-USER 链的 Cloudflare-only 限制"
    else
      MANAGE_DOCKER=0
      warn "未启用 Docker 限制：容器发布的 ${CF_PORTS} 仍可被任意来源直达，绕过 Cloudflare。"
    fi
  else
    MANAGE_DOCKER=0
  fi
}

docker_cleanup() {
  local ipt num chain="GHOST_ORIGIN_DOCKER"
  for ipt in iptables ip6tables; do
    have_cmd "${ipt}" || continue
    "${ipt}" -L DOCKER-USER -n >/dev/null 2>&1 || continue
    while num="$("${ipt}" -L DOCKER-USER --line-numbers -n 2>/dev/null | awk -v c="${chain}" '$0 ~ c {print $1; exit}')" && [[ -n "${num}" ]]; do
      run "${ipt}" -D DOCKER-USER "${num}" >/dev/null 2>&1 || break
    done
    "${ipt}" -F "${chain}" 2>/dev/null || true
    "${ipt}" -X "${chain}" 2>/dev/null || true
  done
}

cmd_install() {
  need_root
  validate_ports_csv "${CF_PORTS}"
  validate_spa_ports "${SPA_PORTS}"
  [[ "${FW_ACCESS_TIMEOUT}" =~ ^[1-9][0-9]{0,3}$ ]] && (( FW_ACCESS_TIMEOUT <= 3600 )) || die "--timeout 必须是 1-3600 秒"
  [[ "${SPA_UDP_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && (( SPA_UDP_PORT <= 65535 )) || die "SPA_UDP_PORT 必须是 1-65535"
  [[ "${SPA_MODE}" == "udp" || "${SPA_MODE}" == "pcap" ]] || die "--spa-mode 必须是 udp 或 pcap"
  have_cmd ip || die "需要 iproute2"
  preflight_ssh_access
  preflight_existing_tools
  resolve_docker_choice

  cat <<EOF
即将配置:
  Cloudflare TCP ${CF_PORTS} 放行（自动拉取官方 CIDR，每日刷新）
  UFW 默认拒绝其他入站
  fwknop SPA 可打开: ${SPA_PORTS}（${FW_ACCESS_TIMEOUT}s）
  SPA 接收模式: ${SPA_MODE}（udp 模式放行 IPv4 UDP/${SPA_UDP_PORT}；pcap 模式不放行）
  SSH 应急规则: $([[ -n "${ALLOW_SSH_FROM}" ]] && echo "允许 ${ALLOW_SSH_FROM} -> TCP/${SSH_PORT}" || echo "无（需先敲门）")
  Docker 限制: $([[ "${MANAGE_DOCKER}" == "1" ]] && echo "启用（容器 ${CF_PORTS} 仅放行 Cloudflare）" || echo "不管理")
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
  generate_keys
  write_fwknop_access
  configure_fwknopd
  validate_fwknop_config
  write_client_rc
  start_fwknop_service
  configure_ufw_policy
  apply_bootstrap_ssh
  apply_initial_whitelist
  enable_services
  write_systemd_timer
  install_cli
  print_summary
}

main() {
  parse_args "$@"
  case "${CMD}" in
    help|-h|--help) usage; exit 0 ;;
    version) printf '%s %s (updated: %s)\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${SCRIPT_UPDATED_AT}"; exit 0 ;;
  esac

  need_root "$@"

  case "${CMD}" in
    install) cmd_install ;;
    update) cmd_update ;;
    update-cf) load_conf; [[ -x "${PREFIX}/sbin/cf-ufw-update" ]] || die "尚未安装，请先 $0 install"; "${PREFIX}/sbin/cf-ufw-update" ;;
    status) cmd_status ;;
    print-client) cmd_print_client ;;
    uninstall) cmd_uninstall ;;
    allow-ip|add-ip|add-whitelist) cmd_allow_ip ;;
    del-ip|delete-ip|remove-ip|whitelist-del) cmd_del_ip ;;
    list-ip|list-whitelist|whitelist) cmd_list_ip ;;
  esac
}

main "$@"
