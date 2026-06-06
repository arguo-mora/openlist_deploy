# OpenList Deploy

在 Debian 12 / Ubuntu 上一键部署 **OpenList + qBittorrent + Aria2** 离线下载环境。

## 一键部署

```bash
curl -fsSL https://openlist-deploy.pages.dev/deploy.sh | bash
```

带参数的非交互模式：

```bash
curl -fsSL https://openlist-deploy.pages.dev/deploy.sh | bash -s -- \
  --domain example.com \
  --email admin@example.com \
  --aria2 \
  -y
```

镜像地址：

```bash
curl -fsSL https://olist.upgyc.top/deploy.sh | bash
```

## CLI 参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--domain` | OpenList 域名 | 无 |
| `--qbit-domain` | qBittorrent 域名 | 无 |
| `--email` | Let's Encrypt 邮箱 | 无 |
| `--base-dir` | 部署根目录 | `/opt/openlist` |
| `--bt-port` | BT 端口 | `62973` |
| `--aria2` / `--no-aria2` | 安装/不安装 Aria2 | 询问 |
| `-y` | 非交互模式 | — |

## 要求

- Debian 12 / Ubuntu
- root 权限
- ≥ 5GB 磁盘，≥ 1.5GB 内存

## 许可证

MIT
