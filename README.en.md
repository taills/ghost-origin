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
- **Dual SPA reception modes**: Default `udp` mode permits the IPv4 UDP transport port to support distribution packages built without libpcap; optional `--spa-mode pcap` keeps the port dropped if supported by the binary.
- **Built-in IP Whitelist Manager**: Easily allow permanent or port-specific access for fixed office IPs, jump hosts, or monitoring agents with safe reverse-order deletion.

> **Why is it called "GhostOrigin"?**  
> To external scanners (Nmap, Shodan, Censys), nearly all origin services appear closed or filtered. In default `udp` mode, only an unauthenticated-drop UDP port (default 62201) receives encrypted authorization packets; in `--spa-mode pcap`, the knock port can remain completely dropped at the firewall layer and sniffed via libpcap.

---

## 🚀 One-Line Quick Install (Recommended)

Run this single command on your server to automatically install and configure everything:

```bash
curl -fsSL https://raw.githubusercontent.com/taills/ghost-origin/main/ghost-origin.sh | sudo bash -s -- install --yes
```

Need custom parameters? Pass flags directly through `bash -s --`:

```bash
# Example: Set knock window to 120s and whitelist an office IP on install
curl -fsSL https://raw.githubusercontent.com/taills/ghost-origin/main/ghost-origin.sh | sudo bash -s -- install \
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
sudo bash ./ghost-origin.sh install --yes
```

### Use the Installed Command

After successful installation, the script installs itself as `/usr/bin/ghost-origin` (root:root, mode `0755`). It no longer depends on the checkout directory. From a root shell:

```bash
sudo -i
ghost-origin status
ghost-origin allow-ip 192.0.2.10 --port 22
ghost-origin list-ip
ghost-origin del-ip 192.0.2.10
ghost-origin update-cf
```

Management commands still reject non-root users; there is no automatic privilege escalation. `ghost-origin --help` does not require root.

Local installation copies the running script. A `curl | bash` installation has no source file, so it downloads the script again from this repository's `main` branch, checks its syntax, and replaces the destination atomically. Because `main` may change between downloads, download and review a pinned version locally when version consistency is required. A failed download leaves any existing command untouched, but does not roll back earlier installation steps. `--dry-run` does not write the command file; `ghost-origin uninstall` also removes it.

All post-install management examples below assume a root shell. Regular users can prefix the entire command with `sudo`.

### Existing Port-Knocking Software Preflight

Before installation, the script checks APT packages, executables in PATH, and systemd services:

- **Existing knockd**: asks separately before removal. After approval, backs up `/etc/knockd.conf` and `/etc/default/knockd`, stops and disables the service if present, and runs `apt-get remove`. No purge or autoremove is performed. The old knocking method will stop working; review existing firewall rules separately.
- **Existing fwknop**: asks separately before upgrading. After approval, backs up `access.conf` and `fwknopd.conf`, then uses `apt-get install --only-upgrade` for installed `fwknop-server` / `fwknop-client` packages. This selects the configured APT repository candidate, not necessarily the latest upstream release. An up-to-date package is unchanged; installation then applies this project's configuration and restarts the service.
- All decisions are collected before system changes. Declining either cancels installation. `--yes` does **not** bypass these prompts. Without a controlling terminal the script exits; rerun interactively. `--dry-run` only previews the plan.
- Detected unmanaged installations require manual handling; unknown files are not deleted. `--skip-apt` is rejected when existing software requires removal or upgrade.

Backups are stored in `/root/ghost-origin-backup/`. A failed upgrade or removal stops installation before firewall configuration; completed package operations are not automatically rolled back. Keep console access or another recovery path when administering remotely.

### Installation Options

| Option | Description | Default |
| --- | --- | --- |
| `--cf-ports 80,443` | TCP ports allowed for Cloudflare CIDRs | `80,443` |
| `--spa-ports tcp/22` | Ports that can be requested via fwknop SPA (e.g. `tcp/22,tcp/2222`) | `tcp/22` |
| `--spa-mode udp\|pcap` | SPA reception mode (`udp` opens IPv4 UDP knock port; `pcap` requires compiled support) | `udp` |
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

> 💡 **Privilege Note**: The script enforces a built-in root check at the main entry point. You can either use `ghost-origin <command>` or switch to a root shell (`sudo -i`) once to run commands directly without repeating `sudo`. Non-root execution is caught upfront with a helpful prompt before any actions take place.

---

## 🔑 Client SPA Knocking (fwknop)

Upon installation, client credentials and configuration are saved to `/root/fwknop-client.rc` on your server.

### Step 1: Install `fwknop` on your client machine

* **macOS**: `brew install fwknop` (or `brew install fwknop wget` if you want automatic IP resolution)
* **Debian / Ubuntu**: `sudo apt install fwknop-client`
* **Arch Linux**: `sudo pacman -S fwknop`
* **Windows**: Download [fwknop-gui](https://www.cipherdyne.org/fwknop/download/) or use WSL

### Step 2: Configure Client Credentials

Append the contents of `/root/fwknop-client.rc` from the server to `~/.fwknoprc` on your laptop:

```ini
[ghost-origin]
SPA_SERVER          YOUR_SERVER_IP
SPA_SERVER_PORT     62201
ACCESS              tcp/22
KEY_BASE64          <Copy from /root/fwknop-client.rc>
HMAC_KEY_BASE64     <Copy from /root/fwknop-client.rc>
USE_HMAC            Y
RESOLVE_IP_HTTPS    Y
# On macOS, if you installed wget via Homebrew, uncomment the line below:
# WGET_CMD          /opt/homebrew/bin/wget
```

### Step 3: Knock and Connect

* **macOS Recommended (No wget required, uses built-in curl to pass public IP)**:
  ```bash
  fwknop -n ghost-origin -a $(curl -s4 ifconfig.me)
  ssh user@YOUR_SERVER_IP
  ```
  > 💡 **macOS Troubleshooting**: If running `fwknop -n ghost-origin` shows `Use --wget-cmd <path> to specify path to the wget command`, this is because macOS does not ship with `wget`, which `RESOLVE_IP_HTTPS` invokes by default. Passing `-a $(curl -s4 ifconfig.me)` directly supplies your public IP using macOS's built-in `curl`; alternatively, run `brew install wget` and configure `WGET_CMD /opt/homebrew/bin/wget` in `~/.fwknoprc`.

* **Standard Method (Linux or macOS with wget installed)**:
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
ghost-origin allow-ip 1.2.3.4
ghost-origin allow-ip 2001:db8::1

# Allow only a specific port (e.g. SSH port 22)
ghost-origin allow-ip 1.2.3.4 --port 22

# Allow an entire CIDR subnet, multiple ports, and attach a comment
ghost-origin allow-ip 192.168.1.0/24 --port 22,8080 --comment "office-lan"

# Allow UDP traffic (e.g. WireGuard VPN)
ghost-origin allow-ip 1.2.3.4 --port 51820 --proto udp --comment "wireguard"

# Batch add multiple IPs (comma-separated)
ghost-origin allow-ip 1.1.2.1,2.2.2.2 --port 22
```

> Aliases: `allow-ip`, `add-ip`, `add-whitelist` are identical.

### 2. List Current Whitelisted IPs

```bash
ghost-origin list-ip
# Or
ghost-origin list-whitelist
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
ghost-origin del-ip 1.2.3.4

# Remove only the rule for a specific port
ghost-origin del-ip 1.2.3.4 --port 22

# Batch remove multiple IPs
ghost-origin del-ip 1.1.2.1,2.2.2.2
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
| **fwknop SPA Knock Packets (UDP 62201)** | **ALLOW (udp mode) / DROP (pcap mode)** | `udp` mode opens IPv4 port; `pcap` mode drops in UFW and captures raw packets |
| **Un-knocked SSH (TCP 22) or Any Other Port** | **DROP / REJECT** | External port scans see ports as closed/filtered |

Cloudflare IP Data Sources:
- IPv4: `https://www.cloudflare.com/ips-v4`
- IPv6: `https://www.cloudflare.com/ips-v6`
- Fallback API: `https://api.cloudflare.com/client/v4/ips`

---

## Update the Script and Check Its Version

```bash
# Root shell: upgrade only the CLI script
ghost-origin update
# Preview without downloading or writing files
ghost-origin update --dry-run
# Version and update date; root is not required
ghost-origin --version
```

Current constants: `SCRIPT_VERSION="1.2.0"` and `SCRIPT_UPDATED_AT="2026-09-17"` (`yyyy-mm-dd`).

`update` downloads from this repository's `main` branch, checks for nonempty content, valid Bash syntax and the entry-point marker, then atomically replaces `/usr/bin/ghost-origin`. Failures preserve the existing command. It does not run `install` or upgrade helper scripts, dependencies, configuration, keys or firewall rules. `update-cf` only refreshes Cloudflare CIDRs. This trusts HTTPS and the repository; syntax checks are not signature verification. The command always fetches main and does not compare version ordering.

If an older installation has no `ghost-origin` or `update` command, download and review the repository script, then run `sudo install -o root -g root -m 0755 ghost-origin.sh /usr/bin/ghost-origin` to install the CLI without rerunning firewall setup.

---

## 🔧 Daily Maintenance

```bash
# Check overall status (UFW rules, Cloudflare CIDR count, whitelist, fwknopd service)
ghost-origin status

# Manually trigger Cloudflare CIDR synchronization
ghost-origin update-cf
# Or invoke the helper script directly
sudo /usr/local/sbin/cf-ufw-update

# Check the daily sync systemd timer
systemctl status cf-ufw-update.timer

# View or reprint client knocking credentials
ghost-origin print-client
```

> 💡 **Post-Install Security Cleanup**: Once you have verified that fwknop SPA knocking works, remove the temporary bootstrap SSH rule created during installation (`comment=cf-ufw-bootstrap`):
> ```bash
> sudo ufw status numbered
> sudo ufw delete <rule_number>
> # Or simply delete your bootstrap IP using del-ip:
> ghost-origin del-ip <YOUR_CURRENT_IP>
> ```

---

## 🗑️ Uninstallation

The uninstall command removes all Cloudflare allow rules, whitelist rules, helper scripts, and systemd timers. It **does not disable UFW** and does not remove APT packages:

```bash
ghost-origin uninstall
```

Original configuration backups are stored under `/root/ghost-origin-backup/`.

---

## 🔒 Security Best Practices

1. **Protect Your Keys**: `/root/fwknop-client.rc` contains symmetric encryption keys and HMAC authentication keys. Ensure file permissions remain `600` and never commit keys to public repositories.
2. **Knock Port Access**: Default `udp` mode requires IPv4 UDP 62201 to be reachable (including any cloud firewall / security groups). When using `--spa-mode pcap`, do not allow that port in UFW.
3. **Keep Cloudflare Proxy Enabled**: Ensure DNS records for your website have the orange cloud (Proxy) enabled in the Cloudflare dashboard so the origin IP is not leaked via DNS resolution.
4. **Backend Neutral**: fwknop's `CMD_CYCLE` hooks interact with UFW at the CLI level rather than injecting custom iptables chains, ensuring full compatibility with both `nftables` and legacy `iptables` backends on modern Linux distributions.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
