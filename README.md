# OpenList Deploy

> [中文文档](README_zh.md)

One-click deployment of **OpenList + qBittorrent + Aria2** offline download environment on Debian 12 / Ubuntu.

The script automatically handles the entire process and prints a summary report at the end:

- System dependencies, timezone, swap creation
- Docker installation and verification
- Directory creation, qBittorrent config preset (fixes Unauthorized 401), permission alignment
- `docker-compose.yml` generation and syntax check
- Container startup and password auto-extraction
- Nginx reverse proxy + Let's Encrypt SSL (optional; auto-enabled when a domain is configured)
- Comprehensive port / permission / HTTP reachability verification

The script is safe to re-run — completed steps are automatically skipped.

## One-Click Deploy

```bash
curl -fsSL https://olist.upgyc.top/deploy.sh | bash
```

> For Chinese users, replace `deploy.sh` with `deploy_zh.sh`.

Non-interactive mode with CLI args:

```bash
curl -fsSL https://olist.upgyc.top/deploy.sh | bash -s -- \
  --domain example.com \
  --email admin@example.com \
  --aria2 \
  -y
```


## CLI Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `--domain` | OpenList domain (prompts interactively if omitted; leave empty for direct IP access) | None |
| `--qbit-domain` | qBittorrent WebUI domain (optional) | None |
| `--email` | Let's Encrypt notification email (required if a domain is configured) | None |
| `--base-dir` | Deployment root directory | `/opt/openlist` |
| `--bt-port` | qBittorrent BT/PT listen port | `62973` |
| `--aria2` | Install Aria2 offline downloader | Prompts |
| `--no-aria2` | Do not install Aria2 | — |
| `--aria2-bt-port` | Aria2 BT listen port | `62974` |
| `--timezone` | System timezone | `Asia/Shanghai` |
| `--puid` | Container runtime UID | `1001` |
| `--pgid` | Container runtime GID | `1001` |
| `-y` / `--non-interactive` | Skip confirmation; run directly (supply all required info via other args) | — |
| `-h` / `--help` | Show help | — |

> **Note**: In `curl|bash` pipe mode, the script automatically reads interactive input from `/dev/tty`, so it works as expected. Non-interactive mode (`-y`) requires all necessary info to be provided via arguments.

## After Deployment

The script prints a summary report with:

- Step-by-step results (OK / Warning / Failed)
- Access URLs (HTTP / HTTPS)
- Port list
- Initial passwords / secrets for each service
- OpenList backend configuration guide for binding downloaders
- SSL certificate expiry date

## Directory Structure

```
/opt/openlist/
├── docker-compose.yml
├── config/
│   ├── openlist/          # OpenList data
│   ├── qbittorrent/       # qBittorrent config
│   └── aria2/             # Aria2 config (optional)
└── temp/
    ├── qBittorrent/       # qBittorrent download temp directory
    └── aria2/             # Aria2 download temp directory (optional)
```

## Requirements

- Debian 12 / Ubuntu (other OS: prints warning but continues)
- Root privileges
- Disk ≥ 3GB (recommended ≥ 5GB; swap creation auto-skipped if < 5GB)
- Memory ≥ 1.5GB recommended (2GB swap auto-created if insufficient)
- For HTTPS: domain DNS resolved to server IP, cloud firewall ports 80/443 open

## Container Overview

| Container | Image | Memory Limit | Ports |
|-----------|-------|-------------|-------|
| openlist | `openlistteam/openlist:latest` | 512M | 5244 |
| qbittorrent | `lscr.io/linuxserver/qbittorrent:latest` | 1G | 8080 (WebUI), BT_PORT |
| aria2 (optional) | `p3terx/aria2-pro:latest` | 512M | 6800 (RPC), ARIA2_BT_PORT |

## Detailed Tutorial

A companion blog post with step-by-step manual instructions, permission deep-dive, troubleshooting guide, and performance tuning:

👉 [OpenList + qBittorrent + Aria2 Deployment Guide](https://blog.arguo.org/tech/openlist-deploy/) (Chinese)

## License

MIT
