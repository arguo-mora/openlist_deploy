#!/bin/bash
#==============================================================================
# OpenList + qBittorrent + Aria2 一键部署脚本 (Debian 12 / Ubuntu)
# 用法: bash deploy.sh  (root 用户)
#
# CLI 参数（可选，不提供则交互式询问）:
#   --domain <domain>        OpenList 域名
#   --qbit-domain <domain>   qBittorrent 域名
#   --email <email>          Let's Encrypt 通知邮箱
#   --base-dir <path>        部署根目录            [默认: /opt/openlist]
#   --bt-port <port>         BT/PT 监听端口        [默认: 62973]
#   --aria2                  安装 Aria2
#   --no-aria2               不安装 Aria2
#   --timezone <tz>          时区                  [默认: Asia/Shanghai]
#   --puid <uid>             容器 UID              [默认: 1001]
#   --pgid <gid>             容器 GID              [默认: 1001]
#   -y, --non-interactive    跳过确认，直接执行
#   -h, --help               显示帮助
#==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# 管道安全：如果 stdin 不是终端（curl|bash），覆盖 read 从 /dev/tty 读取用户输入
# 不能用 exec < /dev/tty，因为 bash 还要从 pipe 读后续脚本内容
if [ ! -t 0 ]; then
    read() { builtin read "$@" < /dev/tty; }
fi

# ---- 可配置默认值 ----
TZ="${TZ:-Asia/Shanghai}"
PUID="${PUID:-1001}"
PGID="${PGID:-1001}"
NON_INTERACTIVE=false

# ---- CLI 参数解析 ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)        DOMAIN="$2"; HAS_DOMAIN="yes"; shift 2 ;;
        --qbit-domain)   QBIT_DOMAIN="$2"; shift 2 ;;
        --email)         EMAIL="$2"; shift 2 ;;
        --base-dir)      BASE_DIR="$2"; shift 2 ;;
        --bt-port)       BT_PORT="$2"; shift 2 ;;
        --aria2)         INSTALL_ARIA2="yes"; shift ;;
        --no-aria2)      INSTALL_ARIA2="no"; shift ;;
        --aria2-bt-port) ARIA2_BT_PORT="$2"; shift 2 ;;
        --timezone)      TZ="$2"; shift 2 ;;
        --puid)          PUID="$2"; shift 2 ;;
        --pgid)          PGID="$2"; shift 2 ;;
        -y|--non-interactive) NON_INTERACTIVE=true; shift ;;
        -h|--help)
            echo "用法: bash deploy.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --domain <domain>        OpenList 域名"
            echo "  --qbit-domain <domain>   qBittorrent 域名"
            echo "  --email <email>          Let's Encrypt 通知邮箱"
            echo "  --base-dir <path>        部署根目录            [默认: /opt/openlist]"
            echo "  --bt-port <port>         BT/PT 监听端口        [默认: 62973]"
            echo "  --aria2                  安装 Aria2"
            echo "  --no-aria2               不安装 Aria2"
            echo "  --aria2-bt-port <port>   Aria2 BT 端口         [默认: 62974]"
            echo "  --timezone <tz>          时区                  [默认: Asia/Shanghai]"
            echo "  --puid <uid>             容器 UID              [默认: 1001]"
            echo "  --pgid <gid>             容器 GID              [默认: 1001]"
            echo "  -y, --non-interactive    跳过确认，直接执行"
            echo "  -h, --help               显示此帮助"
            echo ""
            echo "示例:"
            echo "  bash deploy.sh"
            echo "  bash deploy.sh --domain example.com --email a@b.com -y"
            echo "  bash deploy.sh --domain example.com --aria2 --timezone America/New_York"
            exit 0 ;;
        *)
            echo "未知参数: $1，使用 -h 查看帮助"; exit 1 ;;
    esac
done

declare -a STEP_RESULTS
CRITICAL_FAILURE=0
START_TIME=$(date +%s)
declare -a DEFERRED_INFO
defer_info() { DEFERRED_INFO+=("${1}|${2}"); }

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

record_step() { STEP_RESULTS+=("${1}|${2}|${3:-}"); }
step_header() { echo ""; echo -e "${BOLD}━━━━━━ $1 ━━━━━━${NC}"; }

check_cmd() {
    local name="$1" level="$2" cmd="$3" ok_msg="${4:-}" fail_msg="${5:-}"
    step_header "$name"
    local output exit_code=0
    echo -n "  执行中..."
    if output=$(eval "$cmd" 2>&1); then
        echo -e "\r  ${GREEN}✓${NC} ${ok_msg}"
        [ -n "$output" ] && echo "$output" | tail -15
        record_step "$name" "OK" ""
        return 0
    else
        exit_code=$?
        echo -e "\r  ${YELLOW}⚠${NC} ${fail_msg} (退出码: $exit_code)"
        [ -n "$output" ] && echo "$output" | tail -15
        record_step "$name" "$([ "$level" = "critical" ] && echo "FAIL" || echo "WARN")" \
            "退出码: $exit_code | $(echo "$output" | tail -3 | tr '\n' ' ')"
        if [ "$level" = "critical" ]; then
            CRITICAL_FAILURE=1
            echo -e "${RED}  → 此为关键步骤，终止部署${NC}"
            print_final_report
        fi
        return $exit_code
    fi
}

print_suggestion() {
    case "$1" in
        "基础依赖安装")
            echo "    建议: 检查网络，运行 apt update 查看具体错误" ;;
        "Docker 安装")
            echo "    建议: 检查是否能访问 download.docker.com" ;;
        "Docker 服务验证")
            echo "    建议: systemctl status docker --no-pager" ;;
        "目录创建与权限")
            echo "    建议: 检查磁盘空间 df -h /opt" ;;
        "docker-compose.yml 生成")
            echo "    建议: 检查部署目录是否可写" ;;
        "Docker Compose 语法验证")
            echo "    建议: cd $BASE_DIR && docker compose config 查看错误详情" ;;
        "容器启动")
            echo "    建议: cd $BASE_DIR && docker compose ps"
            echo "    日志: docker compose logs openlist  /  docker compose logs qbittorrent  /  docker compose logs aria2" ;;
        "qBittorrent 配置预置")
            echo "    建议: 检查目录权限 ls -la $BASE_DIR/config/qbittorrent/qBittorrent/" ;;
        "Aria2 RPC 密钥生成")
            echo "    建议: 检查 $BASE_DIR/config/aria2/aria2.conf 是否存在" ;;
        "Aria2 配置预置")
            echo "    建议: 检查目录权限 ls -la $BASE_DIR/config/aria2/" ;;
        "OpenList 密码获取")
            echo "    建议: docker logs openlist 2>&1 | grep -i password" ;;
        "qBittorrent 密码获取")
            echo "    建议: docker logs qbittorrent 2>&1 | grep -i password" ;;
        "Aria2 RPC 密钥获取")
            echo "    建议: docker logs aria2 2>&1 | grep -i 'rpc.secret'"
            echo "    或查看: cat $BASE_DIR/config/aria2/aria2.conf | grep rpc-secret" ;;
        "Nginx + Certbot 安装")
            echo "    建议: apt update && apt install -y nginx certbot" ;;
        "Nginx 语法检查与重载")
            echo "    建议: nginx -t 查看具体错误" ;;
        "SSL 证书申请")
            echo "    建议: 确认域名 DNS 已解析到本服务器 IP"
            echo "    验证: dig +short $DOMAIN"
            echo "    手动: certbot --nginx -d $DOMAIN" ;;
        "qBittorrent SSL 证书申请")
            echo "    建议: 确认域名 DNS 已解析，手动: certbot --nginx -d $QBIT_DOMAIN" ;;
        "证书自动续期验证")
            echo "    建议: certbot renew --dry-run 查看具体输出" ;;
        "关键目录 owner 检查")
            echo "    建议: chown -R ${PUID}:${PGID} $BASE_DIR" ;;
        "qBittorrent 配置文件 owner 检查")
            echo "    建议: chown ${PUID}:${PGID} $BASE_DIR/config/qbittorrent/qBittorrent/qBittorrent.conf" ;;
        "共享目录可写性检查 (qBittorrent)"|"共享目录可写性检查 (Aria2)")
            echo "    建议: 这是下载成功但无法写入网盘的主要原因！"
            echo "    修复: chown -R ${PUID}:${PGID} $BASE_DIR/temp/qBittorrent && chmod -R 755 $BASE_DIR/temp/qBittorrent"
            [ "$INSTALL_ARIA2" = "yes" ] && echo "          chown -R ${PUID}:${PGID} $BASE_DIR/temp/aria2 && chmod -R 755 $BASE_DIR/temp/aria2"
            echo "    重要: OpenList 中挂载的本地存储目录也必须 owner=${PUID}" ;;
        *)  echo "    建议: 查看上方命令输出，根据错误信息排查" ;;
    esac
}

write_config_json() {
    local config_file="$BASE_DIR/config/openlist/config.json"
    local site_url="$1" force_https="${2:-false}"
    local jwt_secret
    jwt_secret=$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')

    if [ ! -f "$config_file" ]; then
        step_header "OpenList 配置文件生成"
        cat > "$config_file" <<CONFJSON
{
  "force": false,
  "site_url": "$site_url",
  "cdn": "",
  "jwt_secret": "$jwt_secret",
  "token_expires_in": 48,
  "scheme": {
    "address": "0.0.0.0",
    "http_port": 5244,
    "https_port": -1,
    "force_https": $force_https,
    "cert_file": "",
    "key_file": "",
    "unix_file": "",
    "unix_file_perm": "",
    "enable_h2c": false
  },
  "temp_dir": "data/temp",
  "bleve_dir": "data/bleve",
  "dist_dir": "",
  "delayed_start": 0,
  "max_connections": 0,
  "max_concurrency": 64,
  "tls_insecure_skip_verify": true
}
CONFJSON
        chown ${PUID}:${PGID} "$config_file" 2>/dev/null || true
        echo -e "${GREEN}  ✓ 配置文件已生成: $config_file${NC}"
        echo -e "     site_url=${site_url}, jwt_secret=${jwt_secret}"
        record_step "OpenList 配置文件生成" "OK" "site_url=$site_url"
    else
        # 已有配置：仅更新 site_url 和 force_https，不动其他字段
        sed -i "s|\"site_url\": \"[^\"]*\"|\"site_url\": \"$site_url\"|" "$config_file"
        sed -i "s|\"force_https\": [a-z]*|\"force_https\": $force_https|" "$config_file"
        if grep -q '"jwt_secret": "random_generated"' "$config_file" 2>/dev/null; then
            sed -i "s|\"jwt_secret\": \"random_generated\"|\"jwt_secret\": \"$jwt_secret\"|" "$config_file"
        fi
        echo -e "${GREEN}  ✓ 配置文件已更新: site_url=${site_url}${NC}"
        record_step "OpenList 配置文件生成" "OK" "已存在，更新 site_url=$site_url"
    fi
}

print_final_report() {
    local end_time=$(date +%s) elapsed=$((end_time - START_TIME))
    local ok_count=0 warn_count=0 fail_count=0
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                    部署结果汇总报告                          ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "║  总耗时: %4d 秒                                               ║\n" "$elapsed"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    for entry in "${STEP_RESULTS[@]}"; do
        local name="${entry%%|*}" rest="${entry#*|}" status="${rest%%|*}" detail="${rest#*|}"
        case "$status" in
            OK)    printf "║  ${GREEN}✓${NC} %-54s ║\n" "$name"; ((ok_count++)) ;;
            WARN)  printf "║  ${YELLOW}⚠${NC} %-54s ║\n" "$name"; ((warn_count++)) ;;
            FAIL)  printf "║  ${RED}✗${NC} %-54s ║\n" "$name"; ((fail_count++)) ;;
        esac
        [ -n "$detail" ] && echo -e "║     ${BLUE}→${NC} $(echo "$detail" | head -c 50)..."
    done
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "║  成功: %-2d  |  警告: %-2d  |  失败: %-2d                            ║\n" "$ok_count" "$warn_count" "$fail_count"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

    if [ "$fail_count" -gt 0 ] || [ "$warn_count" -gt 0 ]; then
        echo ""; echo -e "${BOLD}━━━━━━━━━━━━━━ 排障建议 ━━━━━━━━━━━━━━${NC}"; echo ""
        for entry in "${STEP_RESULTS[@]}"; do
            local name="${entry%%|*}" rest="${entry#*|}" status="${rest%%|*}"
            if [ "$status" = "WARN" ] || [ "$status" = "FAIL" ]; then
                echo -e "  ${YELLOW}▸${NC} ${name}"; print_suggestion "$name"; echo ""
            fi
        done
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi

    if [ "$CRITICAL_FAILURE" -eq 1 ]; then
        echo ""; echo -e "${RED}存在关键步骤失败，部署未完成。修复后重新运行脚本即可。${NC}"
        echo -e "${YELLOW}脚本可安全重复运行，已完成的步骤会自动跳过。${NC}"
    else
        echo ""; echo -e "${GREEN}所有关键步骤已通过。${NC}"
        [ "$warn_count" -gt 0 ] && echo -e "${YELLOW}存在 ${warn_count} 个警告，建议根据上述建议处理。${NC}"
    fi

    # 关键信息汇总：只要有已完成的步骤就显示（即使后续步骤失败）
    if [ -n "$OPENLIST_PWD" ] || [ -n "$QBIT_PWD" ] || [ -n "$ARIA2_RPC_SECRET" ] || [ "$CRITICAL_FAILURE" -eq 0 ]; then
        echo ""; echo -e "${BOLD}━━━━━━━━━━ 关键信息汇总 ━━━━━━━━━━${NC}"; echo ""

        # ── 访问地址 ──
        echo -e "${BOLD}访问地址${NC}"
        if [ "$HAS_DOMAIN" = "yes" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            echo -e "  OpenList:      ${GREEN}https://$DOMAIN${NC}"
        elif [ "$HAS_DOMAIN" = "yes" ]; then
            echo -e "  OpenList:      http://$DOMAIN ${YELLOW}（HTTPS 证书未成功，可手动 certbot 重试）${NC}"
        else
            echo -e "  OpenList:      http://$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || echo '服务器IP'):5244"
        fi
        if [ -n "$QBIT_DOMAIN" ] && [ -f "/etc/letsencrypt/live/$QBIT_DOMAIN/fullchain.pem" ]; then
            echo -e "  qBittorrent:   ${GREEN}https://$QBIT_DOMAIN${NC}"
        elif [ -n "$QBIT_DOMAIN" ]; then
            echo -e "  qBittorrent:   http://$QBIT_DOMAIN ${YELLOW}（HTTPS 未成功）${NC}"
        fi
        echo ""

        # ── 端口 ──
        echo -e "${BOLD}端口${NC}"
        echo "  OpenList:          5244"
        echo "  qBittorrent WebUI: 8080"
        echo "  BT/PT:             ${BT_PORT}"
        if [ "$INSTALL_ARIA2" = "yes" ]; then
            echo "  Aria2 RPC:         6800"
            echo "  Aria2 BT:          ${ARIA2_BT_PORT}"
        fi
        echo -e "  ${BLUE}─────────────────────────────${NC}"
        echo -e "  ${BLUE}可选服务端口（默认关闭，需在 docker-compose 和防火墙额外开放）：${NC}"
        echo "  S3:               5246"
        echo "  FTP:              5221"
        echo "  SFTP:             5222"
        echo ""

        # ── 凭据 ──
        echo -e "${BOLD}凭据${NC}"
        if [ -n "$OPENLIST_PWD" ]; then
            echo -e "  OpenList 初始密码:    ${GREEN}${OPENLIST_PWD}${NC}"
        else
            echo -e "  OpenList 初始密码:    ${YELLOW}未能自动获取${NC}"
        fi
        if [ -n "$QBIT_PWD" ]; then
            echo -e "  qBittorrent 临时密码: ${GREEN}${QBIT_PWD}${NC}"
        else
            echo -e "  qBittorrent 临时密码: ${YELLOW}未能自动获取${NC}"
        fi
        if [ "$INSTALL_ARIA2" = "yes" ]; then
            if [ -n "$ARIA2_SECRET_FROM_LOG" ] && [ "${#ARIA2_SECRET_FROM_LOG}" -gt 4 ]; then
                echo -e "  Aria2 RPC 密钥:       ${GREEN}${ARIA2_SECRET_FROM_LOG}${NC}"
            else
                echo -e "  Aria2 RPC 密钥:       ${GREEN}${ARIA2_RPC_SECRET}${NC}"
            fi
        fi
        echo -e "  ${YELLOW}─────────────────────────────────────────${NC}"
        echo -e "  ${YELLOW}手动获取命令（凭据为空时使用）：${NC}"
        echo "    docker logs openlist 2>&1 | grep -i password"
        echo "    docker logs qbittorrent 2>&1 | grep -i password"
        [ "$INSTALL_ARIA2" = "yes" ] && echo "    docker logs aria2 2>&1 | grep -i 'rpc.secret'"
        echo ""

        # ── OpenList 后台配置 ──
        echo -e "${BOLD}OpenList 后台配置${NC}"
        echo "  1. 设置 → qBittorrent → 地址填写:"
        echo "     http://admin:<qBit密码>@qbittorrent:8080/"
        echo ""
        if [ "$INSTALL_ARIA2" = "yes" ]; then
            echo "  2. 设置 → 其他 → Aria2 地址填写:"
            echo "     http://aria2:6800/jsonrpc"
            echo "     RPC 密钥填写上方「凭据」区的 Aria2 密钥"
            echo ""
        fi
        echo "  3. 前端右下角 → 离线下载 → 选择 qBittorrent 或 Aria2"
        echo ""

        # SSL 证书到期时间
        if [ "$HAS_DOMAIN" = "yes" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            echo -e "${BOLD}SSL 证书${NC}"
            echo "  $(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" 2>/dev/null)"
            echo ""
        fi
        echo -e "${BOLD}提示${NC}"
        echo "  OpenList 默认 tls_insecure_skip_verify=true"
        echo "  若挂载自签名证书的存储后端，此设置可避免 TLS 验证错误"
        echo "  使用正规 CA 证书的后端无需关注此选项"
        echo ""
    fi
    exit ${CRITICAL_FAILURE}
}

# ====================================================================
#                       交互式配置
# ====================================================================

echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   OpenList + qBittorrent + Aria2 一键部署脚本 (Debian 12 / Ubuntu)   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$NON_INTERACTIVE" = true ]; then
    echo -e "${YELLOW}非交互模式：使用 CLI 参数或默认值${NC}"; echo ""
else
    echo -e "${YELLOW}请回答以下配置问题（直接回车使用默认值）${NC}"; echo ""
fi

# OpenList 域名
if [ -z "$HAS_DOMAIN" ]; then
    echo -e "  ${BLUE}OpenList 域名（可选，留空则不配置 HTTPS，直接 IP 访问）${NC}"
    read -p "  OpenList 域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        HAS_DOMAIN="no"
        echo -e "  ${GREEN}→ 不配置域名和 HTTPS，OpenList 将直接暴露 5244 端口${NC}"
    else
        HAS_DOMAIN="yes"
    fi
else
    echo -e "  OpenList 域名: ${DOMAIN:-（无域名，直接 IP 访问）}"
fi

# qBittorrent 域名
if [ -z "$QBIT_DOMAIN" ] && [ "$NON_INTERACTIVE" != true ]; then
    echo ""
    echo -e "  ${BLUE}qBittorrent 域名（可选，留空则不配置）${NC}"
    read -p "  qBittorrent 域名: " QBIT_DOMAIN
    [ -z "$QBIT_DOMAIN" ] && echo -e "  ${GREEN}→ 跳过 qBittorrent 域名配置${NC}"
elif [ -n "$QBIT_DOMAIN" ]; then
    echo "  qBittorrent 域名: $QBIT_DOMAIN"
fi

# 邮箱
if [ -z "$EMAIL" ]; then
    if [ "$HAS_DOMAIN" = "yes" ] || [ -n "$QBIT_DOMAIN" ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            err "配置了域名但未提供 --email 参数（SSL 证书必填）"; exit 1
        fi
        echo ""
        while true; do
            read -p "  Let's Encrypt 通知邮箱: " EMAIL
            [ -n "$EMAIL" ] && break
            echo -e "  ${RED}此项为必填（SSL 证书需要）${NC}"
        done
    else
        EMAIL=""
        echo -e "  ${GREEN}→ 无需配置域名，跳过邮箱${NC}"
    fi
else
    echo "  邮箱:           $EMAIL"
fi

# 部署根目录
if [ -z "$BASE_DIR" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        BASE_DIR="/opt/openlist"
    else
        echo ""
        read -p "  部署根目录 [默认: /opt/openlist]: " BASE_DIR
    fi
fi
BASE_DIR="${BASE_DIR:-/opt/openlist}"
# 路径校验：空格和特殊字符会导致后续 eval 异常
if [ "$BASE_DIR" != "$(printf '%s' "$BASE_DIR" | tr -d '[:space:]')" ]; then
    err "部署路径不能包含空格: $BASE_DIR"; exit 1
fi
if ! printf '%s' "$BASE_DIR" | grep -q '^/[a-zA-Z0-9/_.-]\+$'; then
    err "部署路径包含非法字符（仅允许 字母 数字 / _ . -）: $BASE_DIR"
    exit 1
fi

# BT 端口
if [ -z "$BT_PORT" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        BT_PORT="62973"
    else
        read -p "  BT/PT 监听端口 [默认: 62973]: " BT_PORT
    fi
fi
BT_PORT="${BT_PORT:-62973}"

# Aria2
if [ -z "$INSTALL_ARIA2" ]; then
    echo ""
    echo -e "  ${BLUE}是否安装 Aria2 离线下载？Aria2 支持 HTTP/FTP/BT/磁力链接下载${NC}"
    read -p "  安装 Aria2? [Y/n]: " INSTALL_ARIA2
fi
INSTALL_ARIA2="${INSTALL_ARIA2:-Y}"
if [ "$INSTALL_ARIA2" = "n" ] || [ "$INSTALL_ARIA2" = "N" ] || [ "$INSTALL_ARIA2" = "no" ] || [ "$INSTALL_ARIA2" = "NO" ]; then
    INSTALL_ARIA2="no"
    echo -e "  ${GREEN}→ 跳过 Aria2 安装${NC}"
else
    INSTALL_ARIA2="yes"
    if [ -z "$ARIA2_BT_PORT" ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            ARIA2_BT_PORT="62974"
        else
            read -p "  Aria2 BT 监听端口 [默认: 62974]: " ARIA2_BT_PORT
        fi
    fi
    ARIA2_BT_PORT="${ARIA2_BT_PORT:-62974}"
    if [ "$ARIA2_BT_PORT" = "$BT_PORT" ]; then
        ARIA2_BT_PORT=$((ARIA2_BT_PORT + 1))
        echo -e "  ${YELLOW}→ BT 端口冲突，Aria2 BT 端口自动调整为: ${ARIA2_BT_PORT}${NC}"
    fi
fi

# 确认
echo ""
echo -e "${BOLD}━━━━━━━━━━━━ 配置确认 ━━━━━━━━━━━━${NC}"
echo "  OpenList:       ${DOMAIN:-（无域名，直接 IP 访问）}"
echo "  qBittorrent:    ${QBIT_DOMAIN:-（无独立域名）}"
echo "  Aria2:          ${INSTALL_ARIA2}"
if [ "$INSTALL_ARIA2" = "yes" ]; then
    echo "  Aria2 BT 端口:  ${ARIA2_BT_PORT}"
fi
echo "  邮箱:           ${EMAIL:-（未配置）}"
echo "  部署根目录:     $BASE_DIR"
echo "  BT 端口:        $BT_PORT"
echo "  时区:           $TZ"
echo "  UID/GID:        ${PUID}/${PGID}"
echo ""

if [ "$NON_INTERACTIVE" = true ]; then
    echo -e "${GREEN}→ 非交互模式，自动确认${NC}"
else
    read -p "  确认以上配置? [Y/n] " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo "已取消，请重新运行脚本。"; exit 0
    fi
fi

# ====================================================================
#                       前置检查
# ====================================================================
step_header "前置检查"

if [ "$EUID" -ne 0 ]; then
    err "请用 root 用户运行此脚本"; exit 1
fi
echo -e "${GREEN}  ✓ root 权限${NC}"
echo -e "${GREEN}  ✓ OpenList: ${DOMAIN:-（无域名，直接 IP 访问）}${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ]; then
        echo -e "${GREEN}  ✓ 系统: ${PRETTY_NAME}${NC}"
    else
        warn "当前系统是 $ID，脚本为 Debian/Ubuntu 设计，可能不完全兼容"
        record_step "系统兼容性" "WARN" "当前: $ID，脚本为 Debian/Ubuntu 设计"
    fi
fi

AVAIL_GB=$(df -BG "$(dirname "$BASE_DIR")" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
[ -z "$AVAIL_GB" ] && AVAIL_GB=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
SKIP_SWAP=0
if [ "$AVAIL_GB" -lt 3 ]; then
    err "磁盘剩余仅 ${AVAIL_GB}GB，不足以完成部署（至少需要约 3GB 用于 Docker 镜像和基础文件）"
    record_step "磁盘空间" "FAIL" "剩余: ${AVAIL_GB}GB < 3GB，无法部署"
    echo -e "${RED}  → 请清理磁盘空间后重新运行脚本${NC}"
    exit 1
elif [ "$AVAIL_GB" -lt 5 ]; then
    warn "磁盘剩余 ${AVAIL_GB}GB，偏紧（建议 ≥ 5GB）。将跳过 Swap 创建以节省空间"
    record_step "磁盘空间" "WARN" "剩余: ${AVAIL_GB}GB < 5GB，跳过 Swap"
    SKIP_SWAP=1
else
    echo -e "${GREEN}  ✓ 磁盘空间: ${AVAIL_GB}GB${NC}"
fi

MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo -e "${GREEN}  ✓ 内存: ${MEM_MB}MB${NC}"
if [ "$MEM_MB" -lt 1500 ] && [ "$SKIP_SWAP" -eq 1 ]; then
    warn "内存 < 1.5GB 且磁盘不足无法创建 Swap，部署后请注意监控内存使用"
elif [ "$MEM_MB" -lt 1500 ]; then
    warn "内存 < 1.5GB，脚本将自动创建 Swap"
fi

# ====================================================================
#                       步骤执行
# ====================================================================

check_cmd "基础依赖安装" "critical" \
    'apt update -qq && apt install -y -qq curl wget vim git unzip net-tools gpg' \
    "基础依赖已安装" \
    "安装失败，请检查网络"

check_cmd "时区配置" "optional" \
    "timedatectl set-timezone $TZ && timedatectl | grep 'Time zone'" \
    "时区已设为 $TZ" \
    "时区配置失败"

step_header "Swap 创建"
if [ "$SKIP_SWAP" -eq 1 ]; then
    warn "磁盘空间不足，跳过 Swap 创建"
    record_step "Swap 创建" "WARN" "磁盘不足，跳过"
elif [ ! -f /swapfile ]; then
    check_cmd "Swap 创建" "optional" \
        'dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null && \
         chmod 600 /swapfile && mkswap /swapfile > /dev/null && swapon /swapfile && \
         ( grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab ) && \
         ( grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf ) && \
         sysctl -p > /dev/null 2>&1 && swapon --show | grep -q swapfile' \
        "2GB Swap 创建成功" \
        "Swap 创建失败，检查磁盘空间"
else
    echo -e "${GREEN}  ✓ Swap 已存在，跳过${NC}"
    record_step "Swap 创建" "OK" "已存在，跳过"
fi
step_header "Docker 安装"
if command -v docker &> /dev/null; then
    echo -e "${GREEN}  ✓ Docker 已安装: $(docker --version)${NC}"
    record_step "Docker 安装" "OK" "已安装: $(docker --version)"
else
    check_cmd "Docker 安装" "critical" \
        'for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
             apt remove -y $pkg 2>/dev/null || true
         done && \
         install -m 0755 -d /etc/apt/keyrings && \
         curl -fsSL --connect-timeout 10 --max-time 60 https://download.docker.com/linux/$ID/gpg | \
             gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null && \
         chmod a+r /etc/apt/keyrings/docker.gpg && \
         . /etc/os-release && \
         echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
             https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
             > /etc/apt/sources.list.d/docker.list && \
         apt update -qq && \
         apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' \
        "Docker 安装成功" \
        "Docker 安装失败，检查网络"
fi
# 始终验证 Docker 服务（无论新安装还是已存在）
check_cmd "Docker 服务验证" "critical" \
    'systemctl is-active --quiet docker && docker version --format "{{.Server.Version}}" > /dev/null 2>&1 && echo "Docker $(docker --version)"' \
    "Docker 服务运行正常" \
    "Docker 服务未正常运行"

check_cmd "目录创建与权限" "critical" \
    'mkdir -p "$BASE_DIR"/config/{openlist,qbittorrent} && \
     mkdir -p "$BASE_DIR"/temp/qBittorrent && \
     chown -R ${PUID}:${PGID} "$BASE_DIR" && \
     chmod -R 755 "$BASE_DIR" && \
     test -d "$BASE_DIR/config/openlist" && test -d "$BASE_DIR/temp/qBittorrent"' \
    "目录结构已创建: $BASE_DIR" \
    "目录创建失败"

if [ "$INSTALL_ARIA2" = "yes" ]; then
    check_cmd "Aria2 目录创建" "critical" \
        'mkdir -p "$BASE_DIR"/config/aria2 && \
         mkdir -p "$BASE_DIR"/temp/aria2 && \
         chown -R ${PUID}:${PGID} "$BASE_DIR/config/aria2" "$BASE_DIR/temp/aria2" && \
         chmod -R 755 "$BASE_DIR/config/aria2" "$BASE_DIR/temp/aria2"' \
        "Aria2 目录已创建: $BASE_DIR/config/aria2, $BASE_DIR/temp/aria2" \
        "Aria2 目录创建失败"
fi

# 每次写入 qBit 配置——这三项是修复 Unauthorized 的关键，不管之前是否配置过
check_cmd "qBittorrent 配置预置" "critical" \
    'QBIT_CONF_DIR="$BASE_DIR/config/qbittorrent/qBittorrent"; \
     mkdir -p "$QBIT_CONF_DIR" && \
     cat > "$QBIT_CONF_DIR/qBittorrent.conf" <<CONFEOF
[Preferences]
WebUI\\HostHeaderValidation=false
WebUI\\CSRFProtection=false
WebUI\\LocalHostAuth=false

[BitTorrent]
Session\\Port=${BT_PORT}
CONFEOF
     chown -R ${PUID}:${PGID} "$BASE_DIR/config/qbittorrent" && \
     test -s "$QBIT_CONF_DIR/qBittorrent.conf" && \
     test "$(stat -c %u "$QBIT_CONF_DIR/qBittorrent.conf")" = "${PUID}"' \
    "qBittorrent 配置已预置，owner=${PUID}" \
    "配置预置失败"

if [ "$INSTALL_ARIA2" = "yes" ]; then
    step_header "Aria2 RPC 密钥生成"
    ARIA2_RPC_SECRET=$(openssl rand -hex 16 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || echo "$(date +%s%N)$RANDOM" | md5sum | cut -d' ' -f1)
    echo -e "${GREEN}  ✓ Aria2 RPC 密钥已生成（见下方汇总）${NC}"
    record_step "Aria2 RPC 密钥生成" "OK" "$ARIA2_RPC_SECRET"
fi

step_header "docker-compose.yml 生成"

if [ -f "$BASE_DIR/docker-compose.yml" ]; then
    # 检查已存在的 compose 文件是否包含用户请求的所有服务
    if [ "$INSTALL_ARIA2" = "yes" ] && ! grep -q "container_name: aria2" "$BASE_DIR/docker-compose.yml" 2>/dev/null; then
        warn "docker-compose.yml 已存在，但缺少 aria2 服务定义"
        warn "如需添加 aria2，请手动删除 compose 文件后重新运行脚本："
        warn "  rm -f $BASE_DIR/docker-compose.yml && bash deploy.sh"
        record_step "docker-compose.yml 生成" "WARN" "已存在但缺少 aria2，请手动删除后重试"
    else
        echo -e "${GREEN}  ✓ docker-compose.yml 已存在，跳过生成${NC}"
        record_step "docker-compose.yml 生成" "OK" "已存在，跳过"
    fi
else
    if [ "$HAS_DOMAIN" = "yes" ]; then
        OPENLIST_BIND="127.0.0.1:5244:5244"
        QBIT_BIND="127.0.0.1:8080:8080"
        ARIA2_RPC_BIND="127.0.0.1:6800:6800"
    else
        OPENLIST_BIND="0.0.0.0:5244:5244"
        QBIT_BIND="0.0.0.0:8080:8080"
        ARIA2_RPC_BIND="0.0.0.0:6800:6800"
    fi

    cat > "$BASE_DIR/docker-compose.yml" <<COMPOSE_EOF
services:
  openlist:
    image: openlistteam/openlist:latest
    container_name: openlist
    volumes:
      - ${BASE_DIR}/config/openlist:/opt/openlist/data
      - ${BASE_DIR}/temp/qBittorrent:/opt/openlist/data/temp/qBittorrent
      - ${BASE_DIR}/temp/aria2:/opt/openlist/data/temp/aria2
    ports:
      - "${OPENLIST_BIND}"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - UMASK=022
    restart: unless-stopped
    mem_limit: 512m
    networks:
      openlist_net:
        aliases:
          - openlist

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - WEBUI_PORT=8080
      - BT_PORT=${BT_PORT}
      - TZ=${TZ}
    volumes:
      - ${BASE_DIR}/config/qbittorrent:/config
      - ${BASE_DIR}/temp/qBittorrent:/opt/openlist/data/temp/qBittorrent
    ports:
      - "${QBIT_BIND}"
      - "${BT_PORT}:${BT_PORT}"
      - "${BT_PORT}:${BT_PORT}/udp"
    restart: unless-stopped
    mem_limit: 1g
    networks:
      openlist_net:
        aliases:
          - qbittorrent
COMPOSE_EOF

        if [ "$INSTALL_ARIA2" = "yes" ]; then
            cat >> "$BASE_DIR/docker-compose.yml" <<COMPOSE_EOF

  aria2:
    image: p3terx/aria2-pro:latest
    container_name: aria2
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - UMASK_SET=022
      - RPC_SECRET=${ARIA2_RPC_SECRET}
      - RPC_PORT=6800
      - LISTEN_PORT=${ARIA2_BT_PORT}
      - TZ=${TZ}
      - DISK_CACHE=64M
      - UPDATE_TRACKERS=true
    volumes:
      - ${BASE_DIR}/config/aria2:/config
      - ${BASE_DIR}/temp/aria2:/opt/openlist/data/temp/aria2
      - ${BASE_DIR}/temp/aria2:/downloads
    ports:
      - "${ARIA2_RPC_BIND}"
      - "${ARIA2_BT_PORT}:${ARIA2_BT_PORT}"
      - "${ARIA2_BT_PORT}:${ARIA2_BT_PORT}/udp"
    restart: unless-stopped
    mem_limit: 512m
    networks:
      openlist_net:
        aliases:
          - aria2
COMPOSE_EOF
        fi

        cat >> "$BASE_DIR/docker-compose.yml" <<'COMPOSE_EOF'

networks:
  openlist_net:
    name: openlist_net
COMPOSE_EOF

    if [ -s "$BASE_DIR/docker-compose.yml" ]; then
        echo -e "${GREEN}  ✓ docker-compose.yml 已生成${NC}"
        record_step "docker-compose.yml 生成" "OK" ""
    else
        echo -e "${RED}  ✗ docker-compose.yml 生成失败${NC}"
        record_step "docker-compose.yml 生成" "FAIL" "文件为空"
        CRITICAL_FAILURE=1; print_final_report
    fi
fi

check_cmd "Docker Compose 语法验证" "critical" \
    'cd "$BASE_DIR" && docker compose config > /dev/null 2>&1' \
    "docker-compose.yml 语法正确" \
    "docker-compose.yml 语法错误"

# 在容器启动前生成 config.json，确保 site_url 等关键字段正确
if [ "$HAS_DOMAIN" = "yes" ]; then
    write_config_json "https://$DOMAIN" "false"
else
    write_config_json "http://$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || echo '服务器IP'):5244" "false"
fi

check_cmd "容器启动" "critical" \
    'cd "$BASE_DIR" && \
     docker compose down --remove-orphans 2>/dev/null || true && \
     docker compose up -d 2>&1' \
    "容器已下发启动（镜像拉取可能需要几分钟）" \
    "容器启动失败，请检查 docker compose 日志"

# 等待容器初始化（非关键步骤，仅友好提示）
step_header "等待容器就绪"
info "等待 10 秒让容器完成初始化..."
sleep 10
echo ""
info "当前容器状态（如下方未显示全部容器，可能是镜像仍在拉取中，请耐心等待后手动检查）："
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
echo ""
if [ "$INSTALL_ARIA2" = "yes" ]; then
    info "预期 3 个容器：openlist, qbittorrent, aria2"
else
    info "预期 2 个容器：openlist, qbittorrent"
fi
info "手动检查命令: cd $BASE_DIR && docker compose ps"
record_step "容器就绪等待" "OK" "已等待 10 秒"

step_header "密码获取"

OPENLIST_PWD=$(docker logs openlist 2>&1 | grep -i "initial password" | tail -1 || true)
if [ -n "$OPENLIST_PWD" ]; then
    echo -e "${GREEN}  ✓ OpenList 初始密码已获取${NC}"
    record_step "OpenList 密码获取" "OK" "$OPENLIST_PWD"
else
    OPENLIST_PWD=$(docker logs openlist 2>&1 | grep -i "password" | tail -3 || true)
    if [ -n "$OPENLIST_PWD" ]; then
        echo -e "${YELLOW}  ⚠ 未能精确匹配初始密码，请看下方汇总${NC}"
        record_step "OpenList 密码获取" "WARN" "未精确匹配"
    else
        echo -e "${YELLOW}  ⚠ 未能获取 OpenList 密码，请看下方汇总${NC}"
        record_step "OpenList 密码获取" "WARN" "未能提取"
    fi
fi

QBIT_PWD=$(docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1 || true)
if [ -n "$QBIT_PWD" ]; then
    echo -e "${GREEN}  ✓ qBittorrent 临时密码已获取${NC}"
    record_step "qBittorrent 密码获取" "OK" "$QBIT_PWD"
else
    QBIT_PWD=$(docker logs qbittorrent 2>&1 | grep -i "password" | tail -5 || true)
    if [ -n "$QBIT_PWD" ]; then
        echo -e "${YELLOW}  ⚠ 未能精确匹配 qBit 临时密码，请看下方汇总${NC}"
        record_step "qBittorrent 密码获取" "WARN" "未精确匹配"
    else
        echo -e "${YELLOW}  ⚠ 未能获取 qBittorrent 密码，请看下方汇总${NC}"
        record_step "qBittorrent 密码获取" "WARN" "未能提取"
    fi
fi

if [ "$INSTALL_ARIA2" = "yes" ]; then
    # p3terx/aria2-pro 启动时打印 RPC 密钥，优先从日志提取
    ARIA2_SECRET_FROM_LOG=$(docker logs aria2 2>&1 | grep -i 'rpc.secret\|RPC secret' | tail -1 | sed -n 's/.*[Ss]ecret[=: ]*//p' | awk '{print $1}' || true)
    if [ -n "$ARIA2_SECRET_FROM_LOG" ] && [ "${#ARIA2_SECRET_FROM_LOG}" -gt 4 ]; then
        echo -e "${GREEN}  ✓ Aria2 RPC 密钥已从日志提取${NC}"
        record_step "Aria2 RPC 密钥获取" "OK" "$ARIA2_SECRET_FROM_LOG"
    else
        echo -e "${GREEN}  ✓ Aria2 RPC 密钥已生成${NC}"
        record_step "Aria2 RPC 密钥获取" "OK" "脚本生成: $ARIA2_RPC_SECRET"
    fi
fi

if [ "$HAS_DOMAIN" = "yes" ]; then
    check_cmd "Nginx + Certbot 安装" "critical" \
        'apt install -y -qq nginx certbot python3-certbot-nginx && \
         systemctl enable nginx --quiet && systemctl start nginx && \
         systemctl is-active --quiet nginx' \
        "Nginx 和 Certbot 已安装并启动" \
        "Nginx/Certbot 安装失败"

    step_header "Nginx 反向代理配置"
    cat > "/etc/nginx/sites-available/openlist" <<NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:5244;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 100m;
    }
}
NGINX_EOF
    ln -sf /etc/nginx/sites-available/openlist /etc/nginx/sites-enabled/openlist
    # 如果 default 站点存在，禁用它（原文件保留在 sites-available，可随时恢复）
    if [ -f /etc/nginx/sites-enabled/default ]; then
        warn "检测到 Nginx 默认站点，已禁用"
        rm -f /etc/nginx/sites-enabled/default
    fi

    if [ -f "/etc/nginx/sites-available/openlist" ]; then
        echo -e "${GREEN}  ✓ Nginx 配置已生成${NC}"
        record_step "Nginx 配置" "OK" ""
    else
        echo -e "${RED}  ✗ Nginx 配置生成失败${NC}"
        record_step "Nginx 配置" "FAIL" "文件写入失败"
        CRITICAL_FAILURE=1; print_final_report
    fi

    if [ -n "$QBIT_DOMAIN" ]; then
        cat > "/etc/nginx/sites-available/qbittorrent" <<QBIT_NGINX_EOF
server {
    listen 80;
    server_name ${QBIT_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 100m;
    }
}
QBIT_NGINX_EOF
        ln -sf /etc/nginx/sites-available/qbittorrent /etc/nginx/sites-enabled/qbittorrent
        echo -e "${GREEN}  ✓ qBittorrent Nginx 配置已生成${NC}"
    fi

    check_cmd "Nginx 语法检查与重载" "critical" \
        'nginx -t 2>&1 && systemctl reload nginx' \
        "Nginx 配置正确，已重载" \
        "Nginx 配置有误"

    step_header "SSL 证书申请"
    check_cmd "SSL 证书申请" "optional" \
        'certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" 2>&1 | tail -10; [ ${PIPESTATUS[0]} -eq 0 ]' \
        "SSL 证书申请成功" \
        "SSL 证书申请失败（可能 DNS 未解析）"

    if [ -n "$QBIT_DOMAIN" ]; then
        check_cmd "qBittorrent SSL 证书申请" "optional" \
            'certbot --nginx -d "$QBIT_DOMAIN" --non-interactive --agree-tos -m "$EMAIL" 2>&1 | tail -10; [ ${PIPESTATUS[0]} -eq 0 ]' \
            "qBittorrent SSL 证书申请成功" \
            "qBittorrent SSL 证书申请失败"
    fi

    check_cmd "证书自动续期验证" "optional" \
        'certbot renew --dry-run 2>&1 | grep -qE "Congratulations|success|not yet due"; [ ${PIPESTATUS[0]} -eq 0 ]' \
        "证书续期机制正常" \
        "证书续期测试未通过"

    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        sed -i "s|\"site_url\": \"[^\"]*\"|\"site_url\": \"https://$DOMAIN\"|" "$BASE_DIR/config/openlist/config.json"
        sed -i 's|"force_https": false|"force_https": true|' "$BASE_DIR/config/openlist/config.json"
        info "config.json 已更新为 HTTPS 模式"
        docker restart openlist > /dev/null 2>&1 || true
        info "已重启 OpenList 使配置生效"
    fi
else
    info "未配置域名，跳过 Nginx 和 HTTPS 配置"
    info "OpenList 直接监听 5244 端口，qBittorrent WebUI 监听 8080 端口"
    [ "$INSTALL_ARIA2" = "yes" ] && info "Aria2 RPC 监听 6800 端口"
fi
step_header "最终验证"
# 仅展示，不做强制判断——镜像拉取可能很慢
info "当前容器运行状态："
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
echo ""
RUNNING_COUNT=$(docker ps --filter "status=running" --format "{{.Names}}" 2>/dev/null | wc -l)
if [ "$INSTALL_ARIA2" = "yes" ]; then
    if [ "$RUNNING_COUNT" -ge 3 ]; then
        echo -e "${GREEN}  ✓ 3 个容器均在运行${NC}"
        record_step "容器运行状态" "OK" "3/3 运行中"
    else
        warn "当前 ${RUNNING_COUNT} 个容器在运行（预期 3 个），如镜像仍在拉取请稍等"
        record_step "容器运行状态" "WARN" "${RUNNING_COUNT}/3 运行中"
    fi
else
    if [ "$RUNNING_COUNT" -ge 2 ]; then
        echo -e "${GREEN}  ✓ 2 个容器均在运行${NC}"
        record_step "容器运行状态" "OK" "2/2 运行中"
    else
        warn "当前 ${RUNNING_COUNT} 个容器在运行（预期 2 个），如镜像仍在拉取请稍等"
        record_step "容器运行状态" "WARN" "${RUNNING_COUNT}/2 运行中"
    fi
fi

check_cmd "OpenList 端口验证" "optional" \
    'ss -tlnp | grep -q "5244" && echo "5244 端口已监听"' \
    "OpenList 端口 5244 正常监听" \
    "5244 端口未监听"

check_cmd "qBittorrent WebUI 端口验证" "optional" \
    'ss -tlnp | grep -q "8080" && echo "8080 端口已监听"' \
    "WebUI 端口 8080 正常监听" \
    "8080 端口未监听"

check_cmd "BT 端口验证" "optional" \
    'ss -tlnp | grep -q "${BT_PORT}" && echo "TCP ${BT_PORT} 已监听"' \
    "BT 端口 ${BT_PORT} TCP 正常监听" \
    "${BT_PORT} 端口未监听"

if [ "$INSTALL_ARIA2" = "yes" ]; then
    check_cmd "Aria2 RPC 端口验证" "optional" \
        'ss -tlnp | grep -q "6800" && echo "6800 端口已监听"' \
        "Aria2 RPC 端口 6800 正常监听" \
        "6800 端口未监听"

    check_cmd "Aria2 BT 端口验证" "optional" \
        'ss -tlnp | grep -q "${ARIA2_BT_PORT}" && echo "TCP ${ARIA2_BT_PORT} 已监听"' \
        "Aria2 BT 端口 ${ARIA2_BT_PORT} TCP 正常监听" \
        "${ARIA2_BT_PORT} 端口未监听"
fi
step_header "权限验证（UID ${PUID}）"
# 目录列表在 eval 外构建，避免嵌套引号问题
_OWNER_CHECK_DIRS=("$BASE_DIR/config/openlist" "$BASE_DIR/temp/qBittorrent" "$BASE_DIR/config/qbittorrent")
if [ "$INSTALL_ARIA2" = "yes" ]; then
    _OWNER_CHECK_DIRS+=("$BASE_DIR/config/aria2" "$BASE_DIR/temp/aria2")
fi

_owner_errors=0
for _d in "${_OWNER_CHECK_DIRS[@]}"; do
    _owner=$(stat -c %u "$_d" 2>/dev/null)
    if [ "$_owner" != "${PUID}" ]; then
        echo -e "  ${RED}✗${NC} $_d → owner=$_owner (期望 ${PUID})"
        ((_owner_errors++))
    else
        echo -e "  ${GREEN}✓${NC} $_d → owner=${PUID}"
    fi
done
if [ "$_owner_errors" -eq 0 ]; then
    echo -e "${GREEN}  ✓ 关键目录 owner 均为 ${PUID}${NC}"
    record_step "关键目录 owner 检查" "OK" ""
else
    warn "部分目录 owner 不正确"
    record_step "关键目录 owner 检查" "WARN" "${_owner_errors} 个目录 owner 异常"
fi

check_cmd "qBittorrent 配置文件 owner 检查" "optional" \
    'QBIT_CONF="$BASE_DIR/config/qbittorrent/qBittorrent/qBittorrent.conf"; \
     if [ -f "$QBIT_CONF" ]; then \
         OWNER=$(stat -c %u "$QBIT_CONF"); \
         echo "  $QBIT_CONF → owner=$OWNER"; [ "$OWNER" = "${PUID}" ]; \
     else echo "  配置文件尚未生成"; true; fi' \
    "qBittorrent.conf owner=${PUID}" \
    "配置文件 owner 不正确"

check_cmd "共享目录可写性检查 (qBittorrent)" "optional" \
    'TESTFILE="$BASE_DIR/temp/qBittorrent/.perm_test_$$"; \
     OK=0; \
     touch "$TESTFILE" && chown ${PUID}:${PGID} "$TESTFILE" 2>/dev/null && \
     [ "$(stat -c %u "$TESTFILE")" = "${PUID}" ] && OK=1; \
     rm -f "$TESTFILE"; \
     [ "$OK" -eq 1 ] && echo "  qBittorrent 共享目录可写"' \
    "UID ${PUID} 可在 qBittorrent 临时目录中创建和拥有文件" \
    "目录权限异常，这是下载失败的直接原因"

if [ "$INSTALL_ARIA2" = "yes" ]; then
    check_cmd "共享目录可写性检查 (Aria2)" "optional" \
        'TESTFILE="$BASE_DIR/temp/aria2/.perm_test_$$"; \
         OK=0; \
         touch "$TESTFILE" && chown ${PUID}:${PGID} "$TESTFILE" 2>/dev/null && \
         [ "$(stat -c %u "$TESTFILE")" = "${PUID}" ] && OK=1; \
         rm -f "$TESTFILE"; \
         [ "$OK" -eq 1 ] && echo "  Aria2 共享目录可写"' \
        "UID ${PUID} 可在 Aria2 临时目录中创建和拥有文件" \
        "Aria2 目录权限异常，下载可能无法完成"
fi

if [ "$HAS_DOMAIN" = "yes" ]; then
    check_cmd "Nginx HTTP 验证" "optional" \
        'HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:80/ --connect-timeout 5 2>/dev/null); \
         echo "HTTP 状态码: $HTTP_CODE"; [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ]' \
        "Nginx HTTP 响应正常" \
        "Nginx HTTP 响应异常"

    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        check_cmd "Nginx HTTPS 验证" "optional" \
            'CERT_EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/'"$DOMAIN"'/fullchain.pem" 2>/dev/null | cut -d= -f2); \
             echo "证书到期: $CERT_EXPIRY"' \
            "HTTPS 证书已就绪" \
            "HTTPS 验证失败"
    else
        info "SSL 证书尚未获取，跳过 HTTPS 验证"
        record_step "Nginx HTTPS 验证" "WARN" "证书不存在，请确保 DNS 已解析后重新申请"
    fi
fi

print_final_report
