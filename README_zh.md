# OpenList Deploy

> [English Documentation](README.md)

在 Debian 12 / Ubuntu 上一键部署 **OpenList + qBittorrent + Aria2** 离线下载环境。

脚本会自动完成以下全部流程，并在末尾输出汇总报告：

- 系统依赖安装、时区设置、Swap 创建
- Docker 安装与验证
- 目录创建、qBittorrent 配置预置（修复 Unauthorized 401）、权限对齐
- `docker-compose.yml` 生成与语法验证
- 容器启动、密码自动提取
- Nginx 反向代理 + Let's Encrypt SSL 证书（可选，配域名时自动启用）
- 端口/权限/HTTP 可达性全面验证

脚本可安全重复运行，已完成的步骤会自动跳过。

## 一键部署

```bash
curl -fsSL https://olist.upgyc.top/deploy_zh.sh | bash
```

> English version: replace `deploy_zh.sh` with `deploy.sh`.

带参数的非交互模式：

```bash
curl -fsSL https://olist.upgyc.top/deploy_zh.sh | bash -s -- \
  --domain example.com \
  --email admin@example.com \
  --aria2 \
  -y
```

## CLI 参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--domain` | OpenList 域名（不提供则交互询问，留空即无域名/IP 直连） | 无 |
| `--qbit-domain` | qBittorrent WebUI 域名（可选） | 无 |
| `--email` | Let's Encrypt 通知邮箱（有域名时必填） | 无 |
| `--base-dir` | 部署根目录 | `/opt/openlist` |
| `--bt-port` | qBittorrent BT/PT 监听端口 | `62973` |
| `--aria2` | 安装 Aria2 离线下载器 | 交互询问 |
| `--no-aria2` | 不安装 Aria2 | — |
| `--aria2-bt-port` | Aria2 BT 监听端口 | `62974` |
| `--timezone` | 系统时区 | `Asia/Shanghai` |
| `--puid` | 容器运行 UID | `1001` |
| `--pgid` | 容器运行 GID | `1001` |
| `-y` / `--non-interactive` | 跳过确认直接执行（需配合其他参数提供必要信息） | — |
| `-h` / `--help` | 显示帮助 | — |

> **注意**：`curl|bash` 管道模式下，脚本会自动从 `/dev/tty` 读取交互输入，不影响正常使用。非交互模式（`-y`）则需要提前通过参数提供所有必要信息。

## 部署后

脚本末尾会打印汇总报告，包含：

- 各步骤执行结果（成功/警告/失败）
- 访问地址（HTTP/HTTPS）
- 端口清单
- 各服务初始密码/密钥
- OpenList 后台绑定下载器的配置说明
- SSL 证书到期时间

## 目录结构

```
/opt/openlist/
├── docker-compose.yml
├── config/
│   ├── openlist/          # OpenList 数据
│   ├── qbittorrent/       # qBittorrent 配置
│   └── aria2/             # Aria2 配置（可选）
└── temp/
    ├── qBittorrent/       # qBittorrent 下载临时目录
    └── aria2/             # Aria2 下载临时目录（可选）
```

## 要求

- Debian 12 / Ubuntu（其他系统会提示警告但仍可尝试）
- root 权限
- 磁盘 ≥ 3GB（建议 ≥ 5GB；不足 5GB 会自动跳过 Swap 创建）
- 内存建议 ≥ 1.5GB（不足时脚本会自动创建 2GB Swap）
- 如需 HTTPS：域名已解析到服务器 IP，云安全组已放行 80/443 端口

## 容器与服务

| 容器 | 镜像 | 内存限制 | 端口 |
|------|------|---------|------|
| openlist | `openlistteam/openlist:latest` | 512M | 5244 |
| qbittorrent | `lscr.io/linuxserver/qbittorrent:latest` | 1G | 8080 (WebUI), BT_PORT |
| aria2 (可选) | `p3terx/aria2-pro:latest` | 512M | 6800 (RPC), ARIA2_BT_PORT |

## 详细教程

部署脚本配套的完整教程（含手动步骤、权限原理、排障指南、性能调优）：

👉 [自建离线下载神器：OpenList + qBittorrent + Aria2 一键部署全攻略](https://blog.arguo.org/tech/openlist-deploy/)

## 许可证

MIT
