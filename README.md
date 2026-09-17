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
- **内置安全白名单系统**（一键添加/删除固定 IP，带倒序防误删保护）

> **为什么是“幽灵源站”？**  
> fwknop 默认的 SPA 敲门端口（UDP 62201）**无需**在 UFW 防火墙中放行。`fwknopd` 利用 libpcap 在 Linux 底层网卡直接嗅探校验。对于全网任何扫描器（Nmap / Shodan / Censys），你的服务器所有端口全部处于 Closed/Filtered 闭门状态。

---

## 🚀 一键快速安装（推荐）

直接使用以下单行命令完成全自动安装与配置：

```bash
curl -fsSL https://raw.githubusercontent.com/taills/ghost-origin/main/install.sh | sudo bash -s -- install --yes
```

如果你需要自定义参数（例如放行自定义端口、预设白名单、设置敲门超时）：

```bash
# 示例：设置敲门超时 120 秒，初始放行一个办公网白名单 IP
curl -fsSL https://raw.githubusercontent.com/taills/ghost-origin/main/install.sh | sudo bash -s -- install \
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
sudo ./install.sh install --yes
```

### 安装常用选项

| 选项 | 含义 | 默认值 |
| --- | --- | --- |
| `--cf-ports 80,443` | Cloudflare 永久放行的 TCP 端口 | `80,443` |
| `--spa-ports tcp/22` | 敲门后允许临时打开的端口（可传 `tcp/22,tcp/2222`） | `tcp/22` |
| `--timeout 60` | SPA 敲门规则临时存活时长（秒） | `60` |
| `--ssh-port 22` | SSH 应急规则使用的端口 | `22` |
| `--whitelist-ips "IP1,IP2"` | 初始预设的免敲门白名单 IP 列表 | 无 |
| `--bootstrap-ssh` | 放行当前 SSH 来源 IP（检测到 `SSH_CONNECTION` 时默认开启防锁死） | `auto` |
| `--no-bootstrap-ssh` | 不添加应急 SSH 规则（必须确保立即能敲门） | - |
| `--allow-ssh-from IP` | 指定 IP 的 SSH 永久应急放行 | - |
| `--keep-ufw-rules` | 不执行 `ufw reset`，保留现有自定义规则 | 否（默认清空） |
| `--no-ufw-enable` | 只写规则，不执行 `ufw --force enable` | - |
| `--no-ipv6` | 不处理 IPv6 / 不放行 Cloudflare IPv6 | - |
| `--force-keys` | 强制重新生成 fwknop 密钥（覆盖旧密钥） | 否（优先复用） |
| `--dry-run` | 演练模式：只打印将执行的命令，不做实际更改 | - |
| `-y` / `--yes` | 免交互自动确认 | - |

> ⚠️ 默认安装时会执行 `ufw --force reset` 以确保建立纯净的零信任策略。若机器上已有其他重要 UFW 规则，请务必添加 `--keep-ufw-rules` 选项。

> 💡 **权限说明**：本工具已在入口处内置 root 权限检测。你可以使用 `sudo ./install.sh <子命令>`，或直接执行 `sudo -i` 切换到 root 环境后运行（免去每次重复敲 `sudo`）。非 root 运行时会自动拦截、提示并退出，避免执行半途报错。

---

## 🔑 客户端敲门访问（SPA）

安装完成后，服务器端会自动生成客户端配置并保存在 `/root/fwknop-client.rc`。

### 步骤 1：本地客户端安装 fwknop

* **macOS**: `brew install fwknop`
* **Debian / Ubuntu**: `sudo apt install fwknop-client`
* **Arch Linux**: `sudo pacman -S fwknop`
* **Windows**: 使用 [fwknop-gui](https://www.cipherdyne.org/fwknop/download/) 或 WSL

### 步骤 2：配置客户端

将服务器 `/root/fwknop-client.rc` 的内容追加到你本地电脑的 `~/.fwknoprc` 中：

```ini
[ghost-origin]
SPA_SERVER          YOUR_SERVER_IP
ACCESS              tcp/22
KEY_BASE64          <从服务器 /root/fwknop-client.rc 复制>
HMAC_KEY_BASE64     <从服务器 /root/fwknop-client.rc 复制>
USE_HMAC            Y
RESOLVE_IP_HTTPS    Y
```

### 步骤 3：敲门后连接 SSH

```bash
# 1. 发送加密 SPA 数据包敲门
fwknop -n ghost-origin

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
sudo ./install.sh allow-ip 1.2.3.4
sudo ./install.sh allow-ip 2001:db8::1

# 仅放行特定端口（如 SSH 22 端口）
sudo ./install.sh allow-ip 1.2.3.4 --port 22

# 放行特定网段、多个端口，并附加备注
sudo ./install.sh allow-ip 192.168.1.0/24 --port 22,8080 --comment "office-lan"

# 放行 UDP 端口（例如 WireGuard VPN）
sudo ./install.sh allow-ip 1.2.3.4 --port 51820 --proto udp --comment "wireguard"

# 一次性添加多个 IP（逗号分隔）
sudo ./install.sh allow-ip 1.1.1.1,2.2.2.2 --port 22
```

> 别名支持：`allow-ip`、`add-ip`、`add-whitelist` 效果相同。

### 2. 查看当前白名单列表

```bash
sudo ./install.sh list-ip
# 或
sudo ./install.sh list-whitelist
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
sudo ./install.sh del-ip 1.2.3.4

# 仅删除该 IP 针对特定端口的规则
sudo ./install.sh del-ip 1.2.3.4 --port 22

# 批量删除多个 IP
sudo ./install.sh del-ip 1.1.1.1,2.2.2.2
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
| **fwknop SPA 敲门流量 (UDP 62201)** | **DROP (UFW)** | 防火墙拒绝但 `fwknopd` 在底层嗅探捕获，对外完全不可见 |
| **未敲门的 SSH (TCP 22) 或其他所有入站** | **DROP / REJECT** | 外部扫描探测显示端口关闭/被过滤 |

Cloudflare 官方 IP 数据源：
- IPv4: `https://www.cloudflare.com/ips-v4`
- IPv6: `https://www.cloudflare.com/ips-v6`
- 备用 API: `https://api.cloudflare.com/client/v4/ips`

---

## 🔧 日常维护命令

```bash
# 查看整体状态（UFW 规则、Cloudflare 条数、白名单列表、fwknopd 守护进程状态）
sudo ./install.sh status

# 手动立即同步 Cloudflare 最新 IP 列表
sudo ./install.sh update-cf
# 或直接运行更新脚本
sudo /usr/local/sbin/cf-ufw-update

# 查看每日自动同步定时器
systemctl status cf-ufw-update.timer

# 重新查看/打印客户端敲门配置
sudo ./install.sh print-client
```

> 💡 **安全收尾提示**：验证 fwknop 敲门成功后，请使用以下命令删除安装时自动添加的当前 SSH 临时放行规则（备注为 `cf-ufw-bootstrap`）：
> ```bash
> sudo ufw status numbered
> sudo ufw delete <带有 cf-ufw-bootstrap 备注的规则编号>
> # 或者直接通过 del-ip 删除你的临时 IP：
> sudo ./install.sh del-ip <YOUR_CURRENT_IP>
> ```

---

## 🗑️ 卸载

卸载命令会安全清理所有 Cloudflare 放行规则、白名单规则、辅助脚本与 systemd 定时器，**不会关闭 UFW**，也不会卸载系统软件包：

```bash
sudo ./install.sh uninstall
```

原有的配置文件备份在 `/root/ghost-origin-backup/` 目录下。

---

## 🔒 安全最佳实践

1. **密钥隔离**：`/root/fwknop-client.rc` 包含对称加密密钥与 HMAC 认证密钥，权限应严格保持为 `600`，切勿提交至公开代码仓库。
2. **切勿放行敲门端口**：绝对不要在 UFW 中执行 `ufw allow 62201/udp`。SPA 的隐蔽性核心就在于“敲门端口在防火墙层面是关闭的”。
3. **域名代理开启**：部署在服务器上的站点在 Cloudflare DNS 面板中必须开启小黄云（Proxy 代理），避免源站真实 IP 被 DNS 查询泄露。
4. **底层兼容**：通过 fwknop 的 `CMD_CYCLE` 命令调用 UFW 进行动态开门/关门，完全兼容现代 Linux 系统默认的 nftables/iptables 后端。

---

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 协议开源。
