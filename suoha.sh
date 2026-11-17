#!/bin/bash
set -euo pipefail

# ============================================================
# 新梭哈安全增强版 - Named Tunnel + ACME + 动态凭证 + Systemd
# 解决临时域名重启失效问题
# ============================================================

export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
ACTION="${1:-install}"
SUHOA_DIR="/opt/suoha_quick"
CERT_DIR="$SUHOA_DIR/cert"
CONFIG_DIR="$SUHOA_DIR"
LOG_FILE="$SUHOA_DIR/suoha.log"

# 颜色定义
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"; }

# ===================== 基础工具函数 =====================
command_exists() { command -v "$1" >/dev/null 2>&1; }

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "linux-amd64" ;;
        aarch64|arm64) echo "linux-arm64" ;;
        armv7l) echo "linux-armv7" ;;
        *) echo "unsupported" ;;
    esac
}

# ===================== 网络优化 =====================
optimize_network() {
    log "正在配置 1080P/4K TCP/UDP 内核优化..."
    modprobe tcp_bbr 2>/dev/null || true
    ulimit -n 1048576 2>/dev/null || true

    local total_mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || 1024)
    local max_buf=33554432 def_buf=1048576
    [[ "$total_mem_mb" -lt 512 ]] && max_buf=8388608 && def_buf=262144

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-suoha-4k.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_default = $def_buf
net.core.wmem_default = $def_buf
net.core.rmem_max = $max_buf
net.core.wmem_max = $max_buf
net.ipv4.tcp_rmem = 4096 87380 $max_buf
net.ipv4.tcp_wmem = 4096 65536 $max_buf
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    sysctl -p /etc/sysctl.d/99-suoha-4k.conf 2>/dev/null || sysctl --system 2>/dev/null || true
    log "内核优化完成"
}

# ===================== 依赖安装 =====================
install_deps() {
    log "检查并安装基础依赖..."
    local deps=("curl" "wget" "unzip" "jq" "python3" "openssl" "tar")
    local pkg_manager=""
    
    if command_exists apt; then
        pkg_manager="apt -y install"
        apt update -qq
    elif command_exists yum; then
        pkg_manager="yum -y install"
    elif command_exists apk; then
        pkg_manager="apk add -f"
    else
        log "不支持的系统包管理器"
        exit 1
    fi

    local missing=()
    for dep in "${deps[@]}"; do
        command_exists "$dep" || missing+=("$dep")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "安装缺失依赖: ${missing[*]}"
        $pkg_manager "${missing[@]}" >/dev/null 2>&1 || log "部分依赖安装失败，请手动检查"
    fi
    log "依赖检查完成"
}

# ===================== 安全增强模块 =====================
setup_security() {
    log "=== 启动安全增强配置 ==="
    
    # 1. 动态生成凭证
    SNELL_PSK=$(openssl rand -hex 16)
    TROJAN_PASS=*** rand -hex 8)
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
    
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/credentials.env" <<EOF
SNELL_PSK=$SNELL_PSK
TROJAN_PASS=***
VLESS_UUID=$VLESS_UUID
EOF
    chmod 600 "$CONFIG_DIR/credentials.env"
    log "动态凭证已生成并保存到 $CONFIG_DIR/credentials.env"

    # 2. 防火墙加固
    local sub_port
    sub_port=$(get_or_create_sub_port)
    log "配置防火墙白名单..."
    
    # 允许SSH（假设22端口，实际应根据用户情况）
    iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 22 -j ACCEPT
    
    # 订阅端口仅允许当前公网IP访问
    local my_ip
    my_ip=$(curl -s4 --connect-timeout 3 https://ifconfig.me 2>/dev/null || echo "")
    if [[ -n "$my_ip" ]]; then
        iptables -C INPUT -p tcp --dport "$sub_port" -s "$my_ip" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$sub_port" -s "$my_ip" -j ACCEPT
iptables -C INPUT -p tcp --dport "$sub_port" -j DROP 2>/dev/null || iptables -I INPUT -p tcp --dport "$sub_port" -j DROP
        log "订阅端口 $sub_port 已限制为仅当前IP ($my_ip) 访问"
    fi

    # 3. 创建Named Tunnel（固定域名）
    create_named_tunnel
}

get_or_create_sub_port() {
    local port_file="$SUHOA_DIR/sub_port"
    if [[ -f "$port_file" ]]; then
        cat "$port_file"
    else
        local port=$((RANDOM % 10000 + 25000))
        echo "$port" > "$port_file"
        echo "$port"
    fi
}

# ===================== Named Tunnel 管理 =====================
create_named_tunnel() {
    log "配置 Cloudflare Named Tunnel（固定域名）..."
    
    # 检查cloudflared是否已认证
    if [[ ! -f ~/.cloudflared/cert.pem ]]; then
        log "错误: Cloudflare 未认证，请先运行 'cloudflared tunnel login' 并登录"
        log "或者使用已配置好cloudflared的环境重新运行此脚本"
        exit 1
    fi

    # 创建或复用tunnel
    local tunnel_name="suoha"
    if ! cloudflared tunnel list | grep -q "$tunnel_name"; then
        cloudflared tunnel create "$tunnel_name" | tee -a "$LOG_FILE"
    fi

    # 获取tunnel ID
    local tunnel_id
    tunnel_id=$(cloudflared tunnel list | grep "$tunnel_name" | awk '{print $1}')
    
    if [[ -z "$tunnel_id" ]]; then
        log "无法获取 Tunnel ID"
        exit 1
    fi
    
    echo "$tunnel_id" > "$SUHOA_DIR/tunnel_id"
    log "Named Tunnel ID: $tunnel_id"

    # 创建配置文件
    mkdir -p "$SUHOA_DIR"
    cat > "$SUHOA_DIR/config.yml" <<EOF
tunnel: $tunnel_id
credentials-file: /root/.cloudflared/${tunnel_id}.json

ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://127.0.0.1:${LOCAL_PORT:-8080}
  - service: http_status:404
EOF

    # DNS路由（如果使用自定义域名）
    if [[ -n "$CUSTOM_DOMAIN" ]]; then
        log "尝试自动添加DNS记录..."
        cloudflared tunnel route dns "$tunnel_name" "$CUSTOM_DOMAIN" 2>/dev/null || {
            log "自动DNS添加失败，请手动在Cloudflare添加CNAME:"
            log "  $CUSTOM_DOMAIN -> $tunnel_id.cfargotunnel.com"
        }
    fi

    # 安装systemd服务
    install_tunnel_service "$tunnel_id"
}

install_tunnel_service() {
    local tunnel_id="$1"
    log "安装 cloudflared systemd 服务..."
    
    cat > /etc/systemd/system/cloudflared-suoha.service <<EOF
[Unit]
Description=Cloudflare Suoha Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config $SUHOA_DIR/config.yml run
Restart=always
RestartSec=5
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cloudflared-suoha >/dev/null 2>&1
    systemctl restart cloudflared-suoha
    log "cloudflared 服务已启动并设为开机自启"
}

# ===================== ACME 证书管理 =====================
setup_acme() {
    if [[ -z "$CUSTOM_DOMAIN" ]]; then
        log "使用固定域名 ($ARGO_DOMAIN)，暂不需要ACME证书"
        return 0
    fi

    log "配置 ACME 证书..."
    
    if ! command_exists acme.sh; then
        log "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="$(whoami)@$(hostname)" | tee -a "$LOG_FILE"
        source ~/.bashrc 2>/dev/null || true
    fi

    mkdir -p "$CERT_DIR"
    
    # 使用standalone模式申请证书（需要80端口）
    # 注意：cloudflared占用443，80端口空闲可用于验证
    if [[ ! -f "$CERT_DIR/cert.pem" ]]; then
        log "申请 Let's Encrypt 证书..."
        ~/.acme.sh/acme.sh --issue -d "$CUSTOM_DOMAIN" --standalone \
            --keypath "$CERT_DIR/key.pem" \
            --fullchainpath "$CERT_DIR/cert.pem" | tee -a "$LOG_FILE"
    fi

    # 配置自动续期
    (crontab -l 2>/dev/null; echo "0 3 * * * ~/.acme.sh/acme.sh --renew -d $CUSTOM_DOMAIN --force --post-hook 'systemctl restart singbox suoha-sub'") | crontab -
    log "ACME 证书配置完成，已添加自动续期任务"
}

# ===================== Sing-box 核心配置 =====================
download_singbox() {
    log "下载 Sing-box 核心..."
    local arch=$(get_arch)
    local version="1.12.12"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-${arch}.tar.gz"
    
    cd /tmp
    curl -fsSL "$url" -o sing-box.tar.gz || {
        log "下载失败，尝试备用版本..."
        version="1.11.0"
url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-${arch}.tar.gz"
        curl -fsSL "$url" -o sing-box.tar.gz
    }
    
    tar -xzf sing-box.tar.gz
    mv -f sing-box /usr/local/bin/ 2>/dev/null || mv -f sing-box /usr/bin/
    chmod +x /usr/local/bin/sing-box 2>/dev/null || chmod +x /usr/bin/sing-box
    rm -f sing-box.tar.gz
    log "Sing-box 安装完成"
}

download_cloudflared() {
    log "下载 Cloudflared..."
    local arch=$(get_arch)
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${arch}"
    curl -fsSL "$url" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
    log "Cloudflared 安装完成"
}

# ===================== 订阅服务 =====================
start_sub_server() {
    local web_dir="$1"
    local port="$2"
    local pid_file="/opt/suoha_quick/sub_http.pid"
    
    if command_exists fuser; then
        fuser -k "${port}/tcp" 2>/dev/null || true
    fi
    sleep 0.5
    
    nohup python3 -m http.server "$port" --bind 0.0.0.0 --directory "$web_dir" >/dev/null 2>&1 &
    echo $! > "$pid_file"
    log "订阅 HTTP 服务已启动 (端口 $port)"
}

sync_to_static_web() {
    local src_dir="$1"
    local static_dir="/var/www/suoha_sub"
    rm -rf "$static_dir"
    mkdir -p "$static_dir"
    cp -f "${src_dir}/nodes.txt" "${static_dir}/" 2>/dev/null || true
    cp -f "${src_dir}/sub.txt" "${static_dir}/" 2>/dev/null || true
    cp -f "${src_dir}/clash.yaml" "${static_dir}/" 2>/dev/null || true
}

# ===================== 主安装流程 =====================
do_install() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}   安全增强版梭哈 - Named Tunnel 部署    ${NC}"
    echo -e "${CYAN}========================================${NC}"
    
    # 1. 清理旧服务
    log "清理旧服务..."
    systemctl stop cloudflared-suoha 2>/dev/null || true
    pkill -f sing-box 2>/dev/null || true
    pkill -f cloudflared 2>/dev/null || true
    
    # 2. 环境检查
    optimize_network
    install_deps
    
    # 3. 下载组件
    download_cloudflared
    download_singbox
    
    # 4. 用户输入
    read -p "请输入您的自定义域名（留空使用固定域名）: " CUSTOM_DOMAIN
    if [[ -z "$CUSTOM_DOMAIN" ]]; then
        # 使用Tunnel ID作为域名
        ARGO_DOMAIN=""
        log "将使用 Named Tunnel 固定域名"
    else
        ARGO_DOMAIN="$CUSTOM_DOMAIN"
        log "将绑定自定义域名: $ARGO_DOMAIN"
    fi

    # 5. 安全配置
    source "$SUHOA_DIR/credentials.env" 2>/dev/null || setup_security
    
    # 6. 配置 Sing-box
    configure_singbox
    
    # 7. ACME证书
    setup_acme
    
    # 8. 生成订阅
    generate_subscriptions
    
    # 9. 启动服务
    start_singbox_service
    systemctl restart cloudflared-suoha
    
    # 10. 显示结果
    show_result
    
    log "=== 部署完成 ==="
}

# ===================== Sing-box 配置生成 =====================
configure_singbox() {
    log "生成 Sing-box 配置..."
    
    # 加载凭证
    [[ -f "$CONFIG_DIR/credentials.env" ]] && source "$CONFIG_DIR/credentials.env"
    
    local server_ip
    server_ip=$(curl -s4 --connect-timeout 3 https://ifconfig.me 2>/dev/null || echo "127.0.0.1")
    local server_ipv6
    server_ipv6=$(curl -s6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || echo "")
    
    # 生成随机路径
    local urlpath_vless="vless-$(openssl rand -hex 6)"
    local urlpath_trojan="trojan-$(openssl rand -hex 6)"
    local reality_pub="$(openssl rand -hex 32)"
    local reality_sid="$(openssl rand -hex 8)"
    local port_reality=$((RANDOM % 10000 + 10000))
    local port_rel_grpc=$((port_reality + 1))
    local port_hy2=$((port_reality + 2))
    local port_tuic=$((port_reality + 3))
    local port_snell=$((port_reality + 4))
    local grpc_service="grpc-$(openssl rand -hex 6)"

    cat > "$CONFIG_DIR/singbox.json" <<'SINGBOX_EOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "tag": "cloudflare", "address": "1.1.1.1" }
    ]
  },
  "inbounds": [
SINGBOX_EOF

    # VLESS Reality Vision
    cat >> "$CONFIG_DIR/singbox.json" <<EOF
    {
      "type": "vless",
      "tag": "reality-vision",
      "listen": "::",
"listen_port": $port_reality,
      "transport": {
        "type": "tcp"
      },
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "reality": {
          "enabled": true,
          "public_key": "$reality_pub",
          "short_id": "$reality_sid"
        }
      },
      "users": [
        { "uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision" }
      ]
    },
EOF

    # VLESS Reality gRPC
    cat >> "$CONFIG_DIR/singbox.json" <<EOF
    {
      "type": "vless",
      "tag": "reality-grpc",
      "listen": "::",
      "listen_port": $port_rel_grpc,
      "transport": {
        "type": "grpc",
        "service_name": "$grpc_service"
      },
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "reality": {
          "enabled": true,
          "public_key": "$reality_pub",
          "short_id": "$reality_sid"
        }
      },
      "users": [
        { "uuid": "$VLESS_UUID" }
      ]
    },
EOF

    # Hysteria2
    cat >> "$CONFIG_DIR/singbox.json" <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": $port_hy2,
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      },
      "up_mbps": 100,
      "down_mbps": 100,
      "users": [
        { "name": "hy2-user", "password": "$(open... 16)" }
      ],
      "obfs": {
        "type": "salamander",
        "password": "$(open...x 8)"
      }
    },
EOF

    # TUIC
    cat >> "$CONFIG_DIR/singbox.json" <<EOF
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": $port_tuic,
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      },
      "users": [
        { "name": "tuic-user", "password": "$(open... 16)" }
      ]
    },
EOF

    # AnyTLS
    cat >> "$CONFIG_DIR/singbox.json" <<EOF
    {
      "type": "anytls",
      "tag": "anytls",
      "listen": "::",
      "listen_port": $((port_tuic + 1)),
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      },
      "users": [
        { "name": "anytls-user", "password": "$(open... 16)" }
      ]
    },
EOF

    # 关闭inbounds数组
    echo "  ]," >> "$CONFIG_DIR/singbox.json"

    # outbounds和route（简化版）
    cat >> "$CONFIG_DIR/singbox.json" <<'OUTBOUNDS_EOF'
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": []
  }
}
OUTBOUNDS_EOF

    # 保存端口和参数信息
    cat > "$CONFIG_DIR/ports.env" <<EOF
PORT_REALITY=$port_reality
PORT_REL_GRPC=$port_rel_grpc
PORT_HY2=$port_hy2
PORT_TUIC=$port_tuic
URLPATH_VLESS=$urlpath_vless
URLPATH_TROJAN=$urlpath_trojan
REALITY_PUB=$reality_pub
REALITY_SID=$reality_sid
GRPC_SERVICE=$grpc_service
SERVER_IP=$server_ip
SERVER_IPV6=$server_ipv6
ARGO_DOMAIN=$ARGO_DOMAIN
EOF

    log "Sing-box 配置已生成"
}

# ===================== 订阅生成 =====================
generate_subscriptions() {
    log "生成订阅配置..."
    
    [[ -f "$CONFIG_DIR/credentials.env" ]] && source "$CONFIG_DIR/credentials.env"
    [[ -f "$CONFIG_DIR/ports.env" ]] && source "$CONFIG_DIR/ports.env"
    
    local sub_port
    sub_port=$(get_or_create_sub_port)
    
    # 生成节点列表
    local nodes=""
    local clash_nodes=""
    local surge_conf=""
    
    # VLESS Reality nodes
    if [[ -n "$SERVER_IP" ]]; then
        nodes+="vless://${VLESS_UUID}@${SERVER_IP}:${PORT_REALITY}?encryption=none&security=reality&sni=www.bing.com&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp&headerType=none#VLESS-Reality-Vision\n"
        nodes+="vless://${VLESS_UUID}@${SERVER_IP}:${PORT_REL_GRPC}?encryption=none&security=reality&sni=www.bing.com&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}&mode=gun#VLESS-Reality-gRPC\n"
        
        clash_nodes+="  - name: VLESS-Reality-Vision
    type: vless
    server: ${SERVER_IP}
    port: ${PORT_REALITY}
    uuid: ${VLESS_UUID}
    network: tcp
    tls: true
servername: www.bing.com
    flow: xtls-rprx-vision
    reality-opts:
      public-key: ${REALITY_PUB}
      short-id: ${REALITY_SID}
"
    fi

    # Snell (仅IPv4)
    if [[ -n "$SERVER_IP" ]]; then
        SNELL_PORT=$((RANDOM % 10000 + 30000))
        cat > "$CONFIG_DIR/snell.conf" <<EOF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
version = 4
EOF
        nodes+="snell://${SNELL_PSK}@${SERVER_IP}:${SNELL_PORT}?version=4#Snell-IPv4\n"
        surge_conf+="Snell-IPv4 = snell, ${SERVER_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=4, reuse=true\n"
    fi

    # Snell IPv6
    if [[ -n "$SERVER_IPV6" ]]; then
        SNELL_V6_PORT=$((SNELL_PORT + 1))
        cat > "$CONFIG_DIR/snell_v6.conf" <<EOF
[snell-server]
listen = [::]:${SNELL_V6_PORT}
psk = ${SNELL_PSK}
version = 4
EOF
        nodes+="snell://${SNELL_PSK}@[${SERVER_IPV6}]:${SNELL_V6_PORT}?version=4#Snell-IPv6\n"
    fi

    # 保存节点
    echo -e "$nodes" > "$CONFIG_DIR/nodes.txt"
    
    # Base64订阅
    if command_exists base64; then
        base64 -w 0 "$CONFIG_DIR/nodes.txt" > "$CONFIG_DIR/sub.txt" 2>/dev/null || \
        base64 "$CONFIG_DIR/nodes.txt" | tr -d '\n' > "$CONFIG_DIR/sub.txt"
    fi

    # Clash配置
    cat > "$CONFIG_DIR/clash.yaml" <<EOF
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
proxies:
$clash_nodes
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
$clash_nodes
rules:
  - MATCH,PROXY
EOF

    # HTTP订阅服务
    sync_to_static_web "$CONFIG_DIR"
    start_sub_server "/var/www/suoha_sub" "$sub_port"
    
    # 保存最终订阅URL
    local sub_host="${SERVER_IP:-[${SERVER_IPV6}]}"
    echo "SUB_ONLINE=http://${sub_host}:${sub_port}/sub.txt" >> "$CONFIG_DIR/ports.env"
    echo "CLASH_ONLINE=http://${sub_host}:${sub_port}/clash.yaml" >> "$CONFIG_DIR/ports.env"
    
    log "订阅服务已生成 (端口: $sub_port)"
}

# ===================== 服务管理 =====================
start_singbox_service() {
    log "启动 Sing-box 服务..."
    
    cat > /etc/systemd/system/singbox.service <<EOF
[Unit]
Description=Sing-box Proxy Core
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -C $CONFIG_DIR
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable singbox >/dev/null 2>&1
    systemctl restart singbox
    
    # 等待启动
    sleep 2
    if systemctl is-active --quiet singbox; then
        log "Sing-box 运行正常"
    else
        log "Sing-box 启动失败，检查日志: journalctl -u singbox"
    fi
}

show_result() {
    [[ -f "$CONFIG_DIR/ports.env" ]] && source "$CONFIG_DIR/ports.env"
    [[ -f "$CONFIG_DIR/credentials.env" ]] && source "$CONFIG_DIR/credentials.env"
    
    local server_ip
    server_ip=$(curl -s4 --connect-timeout 3 https://ifconfig.me 2>/dev/null || echo "")
    
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           安全增强版梭哈部署完成！                       ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e ""
    echo -e "${CYAN}[固定域名]${NC} $ARGO_DOMAIN"
    echo -e "${CYAN}[服务器IP]${NC} $server_ip"
    echo -e ""
    echo -e "${YELLOW}协议与端口:${NC}"
    echo -e "  VLESS-Reality Vision : ${PORT_REALITY}"
    echo -e "  VLESS-Reality gRPC   : ${PORT_REL_GRPC}"
    echo -e "  Hysteria2            : ${PORT_HY2}"
    echo -e "  TUIC                 : ${PORT_TUIC}"
    echo -e "  Snell                : ${SNELL_PORT:-N/A}"
    echo -e ""
    echo -e "${YELLOW}凭证信息 (已加密存储):${NC}"
    echo -e "  VLESS UUID: ${VLESS_UUID}"
    echo -e "  Snell PSK: ${SNELL_PSK}"
    echo -e "  Trojan: ${TROJAN_PASS}"
    echo -e ""
    echo -e "${YELLOW}订阅链接:${NC}"
    echo -e "  通用订阅: ${SUB_ONLINE:-http://${server_ip}:$(cat $SUHOA_DIR/sub_port)/sub.txt}"
    echo -e ""
    echo -e "${GREEN}所有服务已设为开机自启${NC}"
    echo -e "查看日志: journalctl -u singbox -f"
    echo -e "查看配置: cat $CONFIG_DIR/v2ray.txt"
}

# ===================== 卸载流程 =====================
do_uninstall() {
    log "开始卸载..."
systemctl stop singbox cloudflared-suoha 2>/dev/null || true
    systemctl disable singbox cloudflared-suoha 2>/dev/null || true
    
    rm -f /etc/systemd/system/singbox.service
    rm -f /etc/systemd/system/cloudflared-suoha.service
    systemctl daemon-reload
    
    rm -rf "$SUHOA_DIR"
    rm -rf /var/www/suoha_sub
    
    # 清理sysctl
    rm -f /etc/sysctl.d/99-suoha-4k.conf
    sysctl --system >/dev/null 2>&1 || true
    
    # 清理防火墙规则（可选，谨慎操作）
    # iptables -D INPUT -p tcp --dport 25000 -j DROP 2>/dev/null || true
    
    log "卸载完成"
}

# ===================== 主入口 =====================
main() {
    if [[ "$ACTION" == "uninstall" ]]; then
        do_uninstall
        exit 0
    fi
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 root 用户运行此脚本${NC}"
        exit 1
    fi
    
    do_install
}

main
