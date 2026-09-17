# cf-ufw-quickstart

在 Debian/Ubuntu 上一键配置：

- **UFW 默认拒绝入站**
- **只允许 Cloudflare 访问 TCP 80/443**（官方 CIDR，每日刷新）
- **其它端口保持关闭**，除非用 **fwknop SPA 敲门** 临时打开（默认 `tcp/22`）

fwknop 的敲门口默认是 UDP 62201。脚本**不会**在 UFW 里放行这个端口：`fwknopd` 用 libpcap 在 INPUT 丢弃之前嗅探，端口对外仍然是关的。

## 安装

```bash
sudo ./install.sh install
```

常用选项：

```bash
sudo ./install.sh install \
  --cf-ports 80,443 \
  --spa-ports tcp/22 \
  --timeout 60 \
  --yes
```

| 选项 | 含义 |
| --- | --- |
| `--cf-ports 80,443` | Cloudflare 永久放行的 TCP 端口 |
| `--spa-ports tcp/22` | 敲门后允许打开的端口（可 `tcp/22,tcp/2222`） |
| `--timeout 60` | 敲门规则存活秒数 |
| `--ssh-port 22` | SSH 应急规则使用的端口 |
| `--bootstrap-ssh` | 放行当前 SSH 来源 IP（默认：检测到 `SSH_CONNECTION` 则开启） |
| `--no-bootstrap-ssh` | 不添加应急 SSH 规则（可能把自己锁在门外） |
| `--allow-ssh-from IP` | 指定 IP 的 SSH 应急放行 |
| `--keep-ufw-rules` | 不执行 `ufw reset`，保留现有规则 |
| `--no-ufw-enable` | 只写规则，不 `ufw --force enable` |
| `--no-ipv6` | 不处理 Cloudflare IPv6 |
| `--force-keys` | 重新生成 fwknop 密钥 |
| `--dry-run` | 只打印将执行的命令 |
| `-y` / `--yes` | 非交互 |

默认会 `ufw --force reset` 再写入策略。机器上已有重要 UFW 规则时请加 `--keep-ufw-rules`。

## 客户端敲门

安装结束后，服务器上的 `/root/fwknop-client.rc` 是客户端 stanza。复制到笔记本的 `~/.fwknoprc`：

```bash
fwknop -n cf-ufw-quickstart
ssh user@SERVER
```

一次性命令（密钥见 `/root/fwknop-client.rc`）：

```bash
fwknop -A tcp/22 -R -D SERVER --use-hmac \
  --key-base64 'KEY' --hmac-key-base64 'HMAC'
ssh user@SERVER
```

客户端需要安装 `fwknop`（Debian/Ubuntu：`fwknop-client`）。

## 生效后的入站策略

| 流量 | 结果 |
| --- | --- |
| Cloudflare IPv4/IPv6 → TCP 80,443 | 允许 |
| 已建立连接 / 回环 | 允许（UFW `before.rules` 默认） |
| SSH（未敲门） | 拒绝（除非还留着 bootstrap 应急规则） |
| fwknop SPA UDP 62201 | UFW 拒绝；daemon 仍能嗅探 |
| 其它入站 | 拒绝 |

Cloudflare 列表来源：

- `https://www.cloudflare.com/ips-v4`
- `https://www.cloudflare.com/ips-v6`
- 失败时回退 `https://api.cloudflare.com/client/v4/ips`

## 白名单 IP 管理（免敲门放行）

默认除了 Cloudflare 访问 80/443 外拒绝一切入站，其他远程访问需通过 fwknop SPA 敲门。如果你有固定办公网、跳板机、监控服务器或家庭宽带 IP，可将其加入白名单，免敲门直连。

### 1. 添加白名单 IP

```bash
# 全端口放行单个 IP（支持 IPv4 与 IPv6）
sudo ./install.sh allow-ip 1.2.3.4
sudo ./install.sh allow-ip 2001:db8::1

# 仅放行特定端口（如 SSH 22 端口）
sudo ./install.sh allow-ip 1.2.3.4 --port 22

# 放行多个端口并添加自定义备注
sudo ./install.sh allow-ip 192.168.1.0/24 --port 22,8080 --comment "office-lan"

# 放行 UDP 端口
sudo ./install.sh allow-ip 1.2.3.4 --port 51820 --proto udp --comment "wireguard"

# 一次性添加多个 IP（逗号分隔）
sudo ./install.sh allow-ip 1.1.1.1,2.2.2.2 --port 22
```

> **别名支持**：`allow-ip`、`add-ip`、`add-whitelist` 均可。

### 2. 查看当前白名单列表

```bash
sudo ./install.sh list-ip
# 或
sudo ./install.sh list-whitelist
```

输出示例：
```
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
# 删除该 IP 的所有白名单规则（无论针对哪个端口）
sudo ./install.sh del-ip 1.2.3.4

# 仅删除该 IP 针对特定端口的规则
sudo ./install.sh del-ip 1.2.3.4 --port 22

# 删除 IPv6 白名单
sudo ./install.sh del-ip 2001:db8::1

# 批量删除多个 IP（逗号分隔）
sudo ./install.sh del-ip 1.1.1.1,2.2.2.2
```

> **安全保护**：删除时按规则号倒序删除（防止规则索引偏移导致误删），且仅会匹配白名单与应急规则，**绝不会误删** Cloudflare 的 80/443 放行规则。  
> **别名支持**：`del-ip`、`delete-ip`、`remove-ip`、`whitelist-del` 均可。

### 4. 安装时直接预置白名单

在执行 `install` 时，可通过 `--whitelist-ips` 预设初始白名单：

```bash
sudo ./install.sh install --whitelist-ips "1.2.3.4,5.6.7.8/24" --yes
```

---

## 日常维护

```bash
sudo ./install.sh status
sudo ./install.sh update-cf          # 立刻刷新 Cloudflare CIDR
sudo ./install.sh print-client       # 打印敲门密钥
sudo /usr/local/sbin/cf-ufw-update
systemctl status cf-ufw-update.timer
```

验证敲门可用后，删掉 comment 为 `cf-ufw-bootstrap` 的 SSH 应急规则：

```bash
sudo ufw status numbered
sudo ufw delete N
```

## 卸载

只移除本脚本写入的规则、helper 和 timer，**不会**关闭 UFW，也不会 `apt remove`：

```bash
sudo ./install.sh uninstall
```

旧的 `access.conf` / `fwknopd.conf` 备份在 `/root/cf-ufw-quickstart-backup/`。

## 安全注意

- 密钥文件权限应为 `600`，不要提交到 git。
- 不要 `ufw allow 62201/udp`。
- 网站必须放在 Cloudflare 代理后面：源站 80/443 只接受 Cloudflare 网段。源站真实 IP 一旦泄露，扫描器仍打不到 SSH，但能打到 Web。
- 本脚本面向 Debian/Ubuntu + systemd。fwknop 通过 `CMD_CYCLE` 改 UFW，不注入 iptables 自定义链，因此兼容 UFW 的 nft/iptables 后端。
