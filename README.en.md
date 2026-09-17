# GhostOrigin (ghost-origin)

English | [简体中文](README.md)

> **Cloudflare at the front door, SPA stealth knock at the back.**  
> *A zero-trust origin server hardening toolkit for web applications fronted by Cloudflare.*

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-orange.svg)](#)
[![Bash](https://img.shields.io/badge/shell-bash%20%3E%3D%204-green.svg)](#)

GhostOrigin turns your origin server completely dark to the public internet:

- **UFW default-deny policy**: Drops all unsolicited incoming traffic by default.
- **Cloudflare-only Web access**: TCP ports 80 and 443 only accept connections from official Cloudflare IPv4 and IPv6 CIDRs (auto-synced daily via a systemd timer).
- **Stealth management ports**: SSH and other administrative ports are completely silent. Access is granted dynamically and temporarily via **fwknop Single Packet Authorization (SPA)** port knocking (default: open for 60 seconds, existing connections stay alive).
- **Built-in IP Whitelist Manager**: Easily allow permanent or port-specific access for fixed office IPs, jump hosts, or monitoring agents with safe reverse-order deletion.

> **Why is it called "GhostOrigin"?**  
> fwknop's default SPA knocking port (`UDP 62201`) is **never opened** in UFW. Instead, the `fwknopd` daemon sniffs raw network frames with `libpcap` before the firewall's `INPUT` drop chain. To any port scanner on the internet (Nmap, Shodan, Censys), every single port on your server is reported as `closed` or `filtered`.

---

## 🚀 One-Line Quick Install (Recommended)

Run this single command on your server to automatically install and configure everything:

```bash
curl -fsSL https://raw.githubusercontent.com/taills/ghost-origin/main/install.sh | sudo bash -s -- install --yes
```

Need custom parameters? Pass flags directly through `bash -s --`:

```bash
# Example: Set knock window to 120s and whitelist an office IP on install
curl -fsSL https://raw.githubusercontent.com/taills/ghost-origin/main/install.sh | sudo bash -s -- install \
  --cf-ports 80,443 \
  --spa-ports tcp/22 \
  --timeout 120 \
  --whitelist-ips "1.2.3.4" \
  --yes
```

---

## 📦 Manual Installation (Git Clone)

```bash
git clone https://github.com/taills/ghost-origin.git
cd ghost-origin
sudo ./install.sh install --yes
```

### Installation Options

| Option | Description | Default |
| --- | --- | --- |
| `--cf-ports 80,443` | TCP ports allowed for Cloudflare CIDRs | `80,443` |
| `--spa-ports tcp/22` | Ports that can be requested via fwknop SPA (e.g. `tcp/22,tcp/2222`) | `tcp/22` |
| `--timeout 60` | Duration (in seconds) the firewall opens after an SPA knock | `60` |
| `--ssh-port 22` | SSH port used for the anti-lockout bootstrap rule | `22` |
| `--whitelist-ips "IP1,IP2"` | Initial list of whitelisted IPs to allow bypass without knocking | None |
| `--bootstrap-ssh` | Automatically allow current SSH source IP to prevent lockout | `auto` |
| `--no-bootstrap-ssh` | Do not add bootstrap SSH rule (ensure you can knock immediately) | - |
| `--allow-ssh-from IP` | Manually specify an IP for emergency SSH access | - |
| `--keep-ufw-rules` | Retain existing UFW rules instead of executing `ufw reset` | No (resets by default) |
| `--no-ufw-enable` | Write rules without running `ufw --force enable` | - |
| `--no-ipv6` | Disable IPv6 support and skip Cloudflare IPv6 CIDRs | - |
| `--force-keys` | Force regeneration of fwknop keys (overwriting existing ones) | No (reuses existing) |
| `--dry-run` | Print commands that would be executed without applying changes | - |
| `-y`, `--yes` | Non-interactive mode (assume Yes to all prompts) | - |

> ⚠️ By default, the installer runs `ufw --force reset` to guarantee a clean zero-trust policy. If you already have critical UFW rules configured, add `--keep-ufw-rules`.

> 💡 **Privilege Note**: The script enforces a built-in root check at the main entry point. You can either use `sudo ./install.sh <command>` or switch to a root shell (`sudo -i`) once to run commands directly without repeating `sudo`. Non-root execution is caught upfront with a helpful prompt before any actions take place.

---

## 🔑 Client SPA Knocking (fwknop)

Upon installation, client credentials and configuration are saved to `/root/fwknop-client.rc` on your server.

### Step 1: Install `fwknop` on your client machine

* **macOS**: `brew install fwknop`
* **Debian / Ubuntu**: `sudo apt install fwknop-client`
* **Arch Linux**: `sudo pacman -S fwknop`
* **Windows**: Download [fwknop-gui](https://www.cipherdyne.org/fwknop/download/) or use WSL

### Step 2: Configure Client Credentials

Append the contents of `/root/fwknop-client.rc` from the server to `~/.fwknoprc` on your laptop:

```ini
[ghost-origin]
SPA_SERVER          YOUR_SERVER_IP
ACCESS              tcp/22
KEY_BASE64          <Copy from /root/fwknop-client.rc>
HMAC_KEY_BASE64     <Copy from /root/fwknop-client.rc>
USE_HMAC            Y
RESOLVE_IP_HTTPS    Y
```

### Step 3: Knock and Connect

```bash
# 1. Send authenticated SPA packet
fwknop -n ghost-origin

# 2. Connect via SSH normally (the port closes after 60s; existing sessions stay open)
ssh user@YOUR_SERVER_IP
```

> **One-liner knock without editing config files**:
> ```bash
> fwknop -A tcp/22 -R -D YOUR_SERVER_IP --use-hmac \
>   --key-base64 'KEY' --hmac-key-base64 'HMAC' && ssh user@YOUR_SERVER_IP
> ```

---

## 🛡️ IP Whitelist Management (Bypass Knocking)

For fixed office IPs, jump hosts, or monitoring agents requiring persistent direct access without knocking, use the built-in whitelist subcommands:

### 1. Add Whitelist IP

```bash
# Allow all ports for an IP (supports IPv4 and IPv6)
sudo ./install.sh allow-ip 1.2.3.4
sudo ./install.sh allow-ip 2001:db8::1

# Allow only a specific port (e.g. SSH port 22)
sudo ./install.sh allow-ip 1.2.3.4 --port 22

# Allow an entire CIDR subnet, multiple ports, and attach a comment
sudo ./install.sh allow-ip 192.168.1.0/24 --port 22,8080 --comment "office-lan"

# Allow UDP traffic (e.g. WireGuard VPN)
sudo ./install.sh allow-ip 1.2.3.4 --port 51820 --proto udp --comment "wireguard"

# Batch add multiple IPs (comma-separated)
sudo ./install.sh allow-ip 1.1.1.1,2.2.2.2 --port 22
```

> Aliases: `allow-ip`, `add-ip`, `add-whitelist` are identical.

### 2. List Current Whitelisted IPs

```bash
sudo ./install.sh list-ip
# Or
sudo ./install.sh list-whitelist
```

Example output:
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

### 3. Remove Whitelist IP

```bash
# Remove all whitelist rules for this IP (across all ports)
sudo ./install.sh del-ip 1.2.3.4

# Remove only the rule for a specific port
sudo ./install.sh del-ip 1.2.3.4 --port 22

# Batch remove multiple IPs
sudo ./install.sh del-ip 1.1.1.1,2.2.2.2
```

> **Safe Deletion**: Deletions only match whitelist (`cf-ufw-whitelist`) and bootstrap rules. Rules are deleted in reverse numerical order, ensuring index stability and **never deleting Cloudflare 80/443 rules**.  
> Aliases: `del-ip`, `delete-ip`, `remove-ip`, `whitelist-del`.

---

## 📊 Inbound Traffic Policy

| Traffic Type | Action | Description |
| --- | --- | --- |
| **Cloudflare IPv4/IPv6 → 80/443 (TCP)** | **ALLOW** | Official published CIDRs, auto-updated daily |
| **Established / Related / Loopback (lo)** | **ALLOW** | Standard UFW stateful tracking |
| **Whitelisted IP Traffic** | **ALLOW** | Explicitly permitted via `allow-ip` |
| **fwknop SPA Knock Packets (UDP 62201)** | **DROP (UFW)** | Dropped by UFW but sniffed at raw PCAP layer; port stays dark |
| **Un-knocked SSH (TCP 22) or Any Other Port** | **DROP / REJECT** | External port scans see ports as closed/filtered |

Cloudflare IP Data Sources:
- IPv4: `https://www.cloudflare.com/ips-v4`
- IPv6: `https://www.cloudflare.com/ips-v6`
- Fallback API: `https://api.cloudflare.com/client/v4/ips`

---

## 🔧 Daily Maintenance

```bash
# Check overall status (UFW rules, Cloudflare CIDR count, whitelist, fwknopd service)
sudo ./install.sh status

# Manually trigger Cloudflare CIDR synchronization
sudo ./install.sh update-cf
# Or invoke the helper script directly
sudo /usr/local/sbin/cf-ufw-update

# Check the daily sync systemd timer
systemctl status cf-ufw-update.timer

# View or reprint client knocking credentials
sudo ./install.sh print-client
```

> 💡 **Post-Install Security Cleanup**: Once you have verified that fwknop SPA knocking works, remove the temporary bootstrap SSH rule created during installation (`comment=cf-ufw-bootstrap`):
> ```bash
> sudo ufw status numbered
> sudo ufw delete <rule_number>
> # Or simply delete your bootstrap IP using del-ip:
> sudo ./install.sh del-ip <YOUR_CURRENT_IP>
> ```

---

## 🗑️ Uninstallation

The uninstall command removes all Cloudflare allow rules, whitelist rules, helper scripts, and systemd timers. It **does not disable UFW** and does not remove APT packages:

```bash
sudo ./install.sh uninstall
```

Original configuration backups are stored under `/root/ghost-origin-backup/`.

---

## 🔒 Security Best Practices

1. **Protect Your Keys**: `/root/fwknop-client.rc` contains symmetric encryption keys and HMAC authentication keys. Ensure file permissions remain `600` and never commit keys to public repositories.
2. **Never Open the Knock Port in UFW**: Do not run `ufw allow 62201/udp`. The entire stealth property of Single Packet Authorization relies on the knock port appearing completely closed to the outside world.
3. **Keep Cloudflare Proxy Enabled**: Ensure DNS records for your website have the orange cloud (Proxy) enabled in the Cloudflare dashboard so the origin IP is not leaked via DNS resolution.
4. **Backend Neutral**: fwknop's `CMD_CYCLE` hooks interact with UFW at the CLI level rather than injecting custom iptables chains, ensuring full compatibility with both `nftables` and legacy `iptables` backends on modern Linux distributions.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
