# GhostOrigin (ghost-origin)

[English](README.en.md) | 简体中文

> **Cloudflare at the front door, SPA stealth knock at the back.**  
> *前门只留 Cloudflare，后门密匙 SPA 敲门。*

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-orange.svg)](#)
[![Bash](https://img.shields.io/badge/shell-bash%20%3E%3D%204-green.svg)](#)

面向 Cloudflare 源站服务器的零信任自动化防护套件：

- **UFW 默认拒绝所有入站**
- **只允许 Cloudflare 访问 TCP 80/443**（官方 CIDR，本地 systemd 定时器每日自动同步）
- **其余端口对外彻底隐身**，除非凭 **fwknop SPA（单包授权）** 敲门按需开门（默认打开 60 秒后自动关门）
- **支持 UDP 与 PCAP 敲门模式**：默认 `udp` 模式放行 IPv4 UDP 敲门传输端口，兼容无 libpcap 的发行版软件包；若环境支持并选用 `--spa-mode pcap`，敲门端口可保持静默丢弃
- **内置安全白名单系统**（一键添加/删除固定 IP，带倒序防误删保护）

> **为什么是“幽灵源站”？**  
> 传统端口扫描器（Nmap / Shodan / Censys）会发现服务器的大部分管理端口处于关闭或过滤状态。在默认的 `udp` 模式下，仅暴露一个只接收合法 SPA 报文的 UDP 端口（默认 62201）；而在自行编译或支持 libpcap 的 `pcap` 模式下，该端口也可在防火墙层面直接丢弃，仅由底层抓包解密。

---

## 🚀 一键快速安装（推荐）

直接使用以下单行命令完成全自动安装与配置：

```bash
curl -fsSL https://raw.githubusercontent.com/taills/ghost-origin/main/ghost-origin.sh | sudo bash -s -- install --yes
```

如果你需要自定义参数（例如放行自定义端口、预设白名单、设置敲门超时）：

```bash
# 示例：设置敲门超时 120 秒，初始放行一个办公网白名单 IP
curl -fsSL https://raw.githubusercontent.com/taills/ghost-origin/main/ghost-origin.sh | sudo bash -s -- install \
  --cf-ports 80,443 \
  --spa-ports tcp/22 \
  --timeout 120 \
  --whitelist-ips "1.2.3.4" \
  --yes
```

---

## 📦 手动安装（Git Clone）

```bash
git clone https://github.com/taills/ghost-origin.git
cd ghost-origin
sudo bash ./ghost-origin.sh install --yes
```

### 安装后直接使用命令

安装成功后，脚本将自身安装为 `/usr/bin/ghost-origin`（root:root，权限 `0755`），不再依赖克隆目录。切换到 root 后即可直接使用：

```bash
sudo -i
ghost-origin status
ghost-origin allow-ip 192.0.2.10 --port 22
ghost-origin list-ip
ghost-origin del-ip 192.0.2.10
ghost-origin update-cf
```

直接执行 `ghost-origin`（不带参数）或 `bash ghost-origin.sh` 会显示帮助并以状态码 0 退出，不安装、不修改系统，也无需 root。仅显式执行 `ghost-origin install` 才进入安装流程；单独传入 `--yes` 不会触发安装。

普通用户直接运行管理命令仍会提示权限不足并退出；不会自动提权。`ghost-origin --help` 无需 root。

本地安装复制正在运行的脚本；`curl | bash` 安装没有源文件，会重新下载上述仓库 `main` 分支脚本，经语法检查后原子替换目标文件。两次下载之间 `main` 可能变化，需固定版本时请下载并审阅同一版本后从本地运行。下载失败不会覆盖已有命令，但此前完成的安装步骤不会自动回滚。`--dry-run` 不写入命令文件；`ghost-origin uninstall` 同时移除该命令。

下文安装后的管理命令均在 root shell 中执行；普通用户可在整条命令前加 `sudo`。

### 安装前检查已有敲门软件

安装前检查 APT 软件包、PATH 中的程序和 systemd 服务：

- **已有 knockd**：单独询问是否移除。确认后备份 `/etc/knockd.conf` 和 `/etc/default/knockd`，停止并禁用服务（若存在），通过 `apt-get remove` 移除软件包；不 purge、不 autoremove。原有敲门方式会失效，既有防火墙规则仍需检查。
- **已有 fwknop**：单独询问是否升级。确认后备份 `access.conf`、`fwknopd.conf`，通过 `apt-get install --only-upgrade` 将已安装的 `fwknop-server` / `fwknop-client` 升级至配置软件源的候选版本。已是最新则保持版本；随后继续应用本项目配置并重启服务。
- 所有确认通过后才开始系统修改。任一拒绝即取消安装。`--yes` **不会跳过**这两项确认；无控制终端时退出，需在交互终端运行。`--dry-run` 只展示计划。
- 检测到非 APT 管理的软件时要求手动处理，不自动删除未知文件。`--skip-apt` 与已有软件的移除/升级流程不兼容，会退出提示。

备份保存在 `/root/ghost-origin-backup/`。升级或卸载命令失败时停止，不继续配置防火墙；已完成的包管理操作不会自动回滚。远程操作前请保留控制台或其他恢复通道。

### 安装常用选项

| 选项 | 含义 | 默认值 |
| --- | --- | --- |
| `--cf-ports 80,443` | Cloudflare 永久放行的 TCP 端口 | `80,443` |
| `--spa-ports tcp/22` | 敲门后允许临时打开的端口（可传 `tcp/22,tcp/2222`） | `tcp/22` |
| `--spa-mode udp\|pcap` | SPA 接收模式（`udp` 默认放行 IPv4 敲门端口；`pcap` 需编译支持） | `udp` |
| `--timeout 60` | SPA 敲门规则临时存活时长（秒） | `60` |
| `--ssh-port 22` | SSH 应急规则使用的端口（未指定时自动探测服务监听端口，默认 `22`） | 自动探测 / `22` |
| `--whitelist-ips "IP1,IP2"` | 初始预设的免敲门白名单 IP 列表 | 无 |
| `--bootstrap-ssh` | 放行当前 SSH 来源 IP（检测到连接时默认开启防锁死） | `auto` |
| `--no-bootstrap-ssh` | 不添加应急 SSH 规则（必须确保立即能敲门） | - |
| `--allow-ssh-from IP` | 指定 IP 的 SSH 应急直连放行（未指定时自动探测并询问用户） | 自动探测询问 |
| `--keep-ufw-rules` | 不执行 `ufw reset`，保留现有自定义规则 | 否（默认清空） |
| `--no-ufw-enable` | 只写规则，不执行 `ufw --force enable` | - |
| `--no-ipv6` | 不处理 IPv6 / 不放行 Cloudflare IPv6 | - |
| `--docker` | 对 Docker 容器发布的 80/443 也仅放行 Cloudflare（写入 `DOCKER-USER` 链） | `auto` |
| `--no-docker` | 不管理 Docker（默认 auto：检测到 Docker 时询问） | `auto` |
| `--force-keys` | 强制重新生成 fwknop 密钥（覆盖旧密钥） | 否（优先复用） |
| `--dry-run` | 演练模式：只打印将执行的命令，不做实际更改 | - |
| `-y` / `--yes` | 免交互自动确认 | - |

> ⚠️ 默认安装时会执行 `ufw --force reset` 以确保建立纯净的零信任策略。若机器上已有其他重要 UFW 规则，请务必添加 `--keep-ufw-rules` 选项。

> 💡 **权限说明**：本工具已在入口处内置 root 权限检测。你可以使用 `ghost-origin <子命令>`，或直接执行 `sudo -i` 切换到 root 环境后运行（免去每次重复敲 `sudo`）。非 root 运行时会自动拦截、提示并退出，避免执行半途报错。

### Docker 容器发布端口的放行（重要）

**Docker 用 `-p` 发布端口时会绕过 UFW**（Docker 直接在 iptables 的 `DOCKER-USER` / DNAT 链插规则，在 UFW 之前生效）。因此仅靠默认的 UFW 规则，容器发布的 80/443 对任何来源都是可达的，会架空「仅 Cloudflare」策略。

本脚本安装时若检测到 Docker（存在 `DOCKER-USER` 链）会询问是否一并接管；确认后（或加 `--docker`）会：

- 创建并维护自管链 `GHOST_ORIGIN_DOCKER`：逐条放行 Cloudflare 网段、丢弃其余；
- 在 `DOCKER-USER` 链插入一条跳转，**仅匹配「从默认路由网卡新建、目的端口为 `--cf-ports`」的入站流量**（`-i <网卡> --ctstate NEW`），因此**不影响容器出站与容器间通信**；
- 由 `cf-ufw-update` 每日随 Cloudflare 网段一起刷新；卸载时自动清理该链。

> ⚠️ **限制**：`docker` / `dockerd` 服务重启会重建 `DOCKER-USER` 链、清掉我们的跳转。重启 Docker 后请执行 `ghost-origin update-cf` 重新同步（每日定时器也会自动补回）。IPv6 为尽力而为（需 Docker 启用 ip6tables）。仅使用宿主网络（`network_mode: host`）的容器走宿主 INPUT，本就受 UFW 保护，无需此项。

---

## 🔑 客户端敲门访问（SPA）

安装完成后，服务器端会自动生成客户端配置并保存在 `/root/fwknop-client.rc`。

### 步骤 1：本地客户端安装 fwknop

* **macOS**: `brew install fwknop`（若需在客户端自动解析公网 IP 可同时 `brew install wget`）
* **Debian / Ubuntu**: `sudo apt install fwknop-client`
* **Arch Linux**: `sudo pacman -S fwknop`
* **Windows**: 使用 [fwknop-gui](https://www.cipherdyne.org/fwknop/download/) 或 WSL

### 步骤 2：配置客户端

将服务器 `/root/fwknop-client.rc` 的内容追加到你本地电脑的 `~/.fwknoprc` 中。**配置段名称使用该服务器的实际 IP**（例如 `[192.0.2.1]`），多台服务器互不冲突：

```ini
[YOUR_SERVER_IP]
SPA_SERVER          YOUR_SERVER_IP
SPA_SERVER_PORT     62201
ACCESS              tcp/22
KEY_BASE64          <从服务器 /root/fwknop-client.rc 复制>
HMAC_KEY_BASE64     <从服务器 /root/fwknop-client.rc 复制>
USE_HMAC            Y
RESOLVE_IP_HTTPS    Y
# macOS 若已通过 brew 安装 wget，取消下一行注释即可（Apple Silicon 路径）：
# WGET_CMD          /opt/homebrew/bin/wget
```

### 步骤 3：敲门后连接 SSH

* **macOS 推荐免配置方式（无需安装 wget，使用自带 curl 动态传入公网 IP）**：
  ```bash
  fwknop -n YOUR_SERVER_IP -a $(curl -s4 ifconfig.me)
  ssh user@YOUR_SERVER_IP
  ```
  > 💡 **macOS 报错排查**：若直接运行 `fwknop -n YOUR_SERVER_IP` 提示 `Use --wget-cmd <path> to specify path to the wget command`，原因在于 macOS 未内置 `wget`，而 `RESOLVE_IP_HTTPS` 默认调用 `wget`。使用 `-a $(curl -s4 ifconfig.me)` 可直接通过系统自带的 `curl` 传入本地公网 IP 敲门；或者运行 `brew install wget` 并在 `~/.fwknoprc` 中指定 `WGET_CMD /opt/homebrew/bin/wget`。

* **通用方式（Linux 或 macOS 已安装 wget）**：
  ```bash
  # 1. 发送加密 SPA 数据包敲门
  fwknop -n YOUR_SERVER_IP

  # 2. 正常连接 SSH（防火墙为你打开 60 秒后自动关门，已建立的连接不受影响）
  ssh user@YOUR_SERVER_IP
  ```

> **一次性单行命令敲门（无需写入配置文件）**：
> ```bash
> fwknop -A tcp/22 -R -D YOUR_SERVER_IP --use-hmac \
>   --key-base64 'KEY' --hmac-key-base64 'HMAC' && ssh user@YOUR_SERVER_IP
> ```

---

## 🛡️ 白名单 IP 管理（免敲门直连）

对于办公网固定出口、跳板机、监控节点等需要长期直连的 IP，可通过白名单管理命令直接放行：

### 1. 添加白名单 IP

```bash
# 全端口放行单个 IP（支持 IPv4 与 IPv6）
ghost-origin allow-ip 1.2.3.4
ghost-origin allow-ip 2001:db8::1

# 仅放行特定端口（如 SSH 22 端口）
ghost-origin allow-ip 1.2.3.4 --port 22

# 放行特定网段、多个端口，并附加备注
ghost-origin allow-ip 192.168.1.0/24 --port 22,8080 --comment "office-lan"

# 放行 UDP 端口（例如 WireGuard VPN）
ghost-origin allow-ip 1.2.3.4 --port 51820 --proto udp --comment "wireguard"

# 一次性添加多个 IP（逗号分隔）
ghost-origin allow-ip 1.1.2.1,2.2.2.2 --port 22
```

> 别名支持：`allow-ip`、`add-ip`、`add-whitelist` 效果相同。

### 2. 查看当前白名单列表

```bash
ghost-origin list-ip
# 或
ghost-origin list-whitelist
```

输出示例：
```text
=== 当前 UFW 白名单 IP 规则 ===
规则号  目标端口/协议           来源 IP/网段                  备注
------  -------------           ------------                  ----
[2   ]  22/tcp                  1.2.3.4                       cf-ufw-whitelist
[3   ]  Anywhere                1.2.3.4                       cf-ufw-whitelist:home
[4   ]  8080/tcp                5.6.7.8                       cf-ufw-whitelist
[5   ]  Anywhere (v6)           2001:db8::1                   cf-ufw-whitelist
[6   ]  22/tcp (v6)             2001:db8::1                   cf-ufw-whitelist:office

共计 5 条白名单规则。
```

### 3. 删除白名单 IP

```bash
# 删除该 IP 的所有白名单规则
ghost-origin del-ip 1.2.3.4

# 仅删除该 IP 针对特定端口的规则
ghost-origin del-ip 1.2.3.4 --port 22

# 批量删除多个 IP
ghost-origin del-ip 1.1.2.1,2.2.2.2
```

> **防误删保护**：删除时仅检索白名单（`cf-ufw-whitelist`）与临时应急规则，且采用规则号倒序删除，**绝不会误删** Cloudflare 的 80/443 规则。  
> 别名支持：`del-ip`、`delete-ip`、`remove-ip`、`whitelist-del`。

---

## 📊 生效后的入站策略

| 流量类型 | 处理方式 | 说明 |
| --- | --- | --- |
| **Cloudflare IPv4/IPv6 → 80/443 (TCP)** | **ALLOW** | 官方公布 CIDR 放行，systemd 每日自动更新 |
| **已建立连接 / 回环接口 (lo)** | **ALLOW** | UFW 默认机制，现有连接不中断 |
| **白名单 IP 流量** | **ALLOW** | 手动添加的免敲门 IP/网段与端口 |
| **Docker 容器发布的 80/443** | **仅 Cloudflare（启用 --docker 时）** | 通过 `DOCKER-USER` 链限制；未启用时 Docker 会绕过 UFW |
| **fwknop SPA 敲门传输 (UDP 62201)** | **ALLOW (udp 模式) / DROP (pcap 模式)** | `udp` 模式放行 IPv4 传输端口；`pcap` 模式防火墙拒绝并由底层捕获 |
| **未敲门的 SSH (TCP 22) 或其他所有入站** | **DROP / REJECT** | 外部扫描探测显示端口关闭/被过滤 |

Cloudflare 官方 IP 数据源：
- IPv4: `https://www.cloudflare.com/ips-v4`
- IPv6: `https://www.cloudflare.com/ips-v6`
- 备用 API: `https://api.cloudflare.com/client/v4/ips`

---

## 升级脚本与查看版本

```bash
# root shell：仅升级命令脚本
ghost-origin update
# 预览升级，不下载或修改文件
ghost-origin update --dry-run
# 无需 root 即可查询版本及更新时间
ghost-origin --version
```

当前版本常量为 `SCRIPT_VERSION="1.4.0"`，更新时间常量为 `SCRIPT_UPDATED_AT="2026-09-17"`（`yyyy-mm-dd`）。

`update` 从本仓库 `main` 分支下载脚本，检查非空、Bash 语法及入口标记后原子替换 `/usr/bin/ghost-origin`。失败时保留旧命令。该操作不执行 `install`，不更新辅助脚本、依赖、配置、密钥或防火墙规则；`update-cf` 仅同步 Cloudflare 网段，与脚本升级不同。这里依赖 HTTPS 和仓库可信性，语法检查不等于签名验证；始终获取 main，不进行版本大小比较。

旧版本若尚未提供 `ghost-origin` 或 `update`，先从仓库下载并审阅脚本，再用 `sudo install -o root -g root -m 0755 ghost-origin.sh /usr/bin/ghost-origin` 安装命令，无需重跑防火墙安装。

---

## 🔧 日常维护命令

```bash
# 查看整体状态（UFW 规则、Cloudflare 条数、白名单列表、fwknopd 守护进程状态）
ghost-origin status

# 手动立即同步 Cloudflare 最新 IP 列表
ghost-origin update-cf
# 或直接运行更新脚本
sudo /usr/local/sbin/cf-ufw-update

# 查看每日自动同步定时器
systemctl status cf-ufw-update.timer

# 重新查看/打印客户端敲门配置
ghost-origin print-client
```

> 💡 **安全收尾提示**：验证 fwknop 敲门成功后，请使用以下命令删除安装时自动添加的当前 SSH 临时放行规则（备注为 `cf-ufw-bootstrap`）：
> ```bash
> sudo ufw status numbered
> sudo ufw delete <带有 cf-ufw-bootstrap 备注的规则编号>
> # 或者直接通过 del-ip 删除你的临时 IP：
> ghost-origin del-ip <YOUR_CURRENT_IP>
> ```

---

## 🗑️ 卸载

卸载命令会安全清理所有 Cloudflare 放行规则、白名单规则、辅助脚本与 systemd 定时器，**不会关闭 UFW**，也不会卸载系统软件包：

```bash
ghost-origin uninstall
```

原有的配置文件备份在 `/root/ghost-origin-backup/` 目录下。

---

## 🔒 安全最佳实践

1. **密钥隔离**：`/root/fwknop-client.rc` 包含对称加密密钥与 HMAC 认证密钥，权限应严格保持为 `600`，切勿提交至公开代码仓库。
2. **敲门端口放行**：默认 `udp` 模式需要 IPv4 UDP 62201 可达（包括云厂商安全组）；若切换到 `--spa-mode pcap`，不要手动放行该端口。
3. **域名代理开启**：部署在服务器上的站点在 Cloudflare DNS 面板中必须开启小黄云（Proxy 代理），避免源站真实 IP 被 DNS 查询泄露。
4. **底层兼容**：通过 fwknop 的 `CMD_CYCLE` 命令调用 UFW 进行动态开门/关门，完全兼容现代 Linux 系统默认的 nftables/iptables 后端。

---

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 协议开源。
