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
