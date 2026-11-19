#!/usr/bin/env bash
# Suoha V2 - multi-distro sing-box deployment manager
# Supported: Ubuntu, Debian, Alpine | init: systemd / OpenRC
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.1.1"
APP="suoha-v2"
BASE="/opt/suoha-v2"
ETC="/etc/suoha-v2"
ACME_HOME="$ETC/acme"
ACME_CONFIG_HOME="$ETC/acme-config"
CERT_DIR="$ETC/cert"
LOG_DIR="/var/log/suoha-v2"
LOG_FILE="$LOG_DIR/install.log"
SB_CONFIG="$ETC/config.json"
CREDENTIALS="$ETC/credentials.env"
SUB_DIR="$ETC/subscription"
SUB_SERVER="$ETC/sub_server.py"
ARGO_ROUTER="$ETC/argo_router.py"
ARGO_ROUTER_PORT=18079
ARGO_VLESS_PORT=18081
ARGO_TROJAN_PORT=18082
ARGO_VMESS_PORT=18083
SB_VERSION="1.14.4"  # stable release; update deliberately after config-schema validation
CF_VERSION="latest"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

log(){ printf '%b[%s] %s%b\n' "$CYAN" "$(date '+%F %T')" "$*" "$NC" | tee -a "$LOG_FILE"; }
warn(){ printf '%b[WARN] %s%b\n' "$YELLOW" "$*" "$NC" | tee -a "$LOG_FILE"; }
die(){ printf '%b[ERROR] %s%b\n' "$RED" "$*" "$NC" | tee -a "$LOG_FILE" >&2; exit 1; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }

cleanup_tmp(){ [[ -n "${TMP_WORK:-}" && -d "$TMP_WORK" ]] && rm -rf "$TMP_WORK" || true; }
trap cleanup_tmp EXIT
trap 'rc=$?; log "脚本在第 ${LINENO} 行失败，退出码 ${rc}"; exit "$rc"' ERR

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"; }

 detect_platform(){
  [[ -r /etc/os-release ]] || die "无法识别发行版：缺少 /etc/os-release"
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  case "$OS_ID" in
    ubuntu|debian) PKG="apt" ;;
    alpine) PKG="apk" ;;
    *) die "暂不支持此发行版：$OS_ID（仅 Ubuntu / Debian / Alpine）" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64"; SB_ARCH="amd64"; CF_ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64"; SB_ARCH="arm64"; CF_ARCH="arm64" ;;
    *) die "暂不支持 CPU 架构：$(uname -m)" ;;
  esac
  if command_exists systemctl && [[ -d /run/systemd/system ]]; then INIT="systemd"; elif command_exists rc-service && [[ -d /run/openrc ]]; then INIT="openrc"; else INIT="none"; fi
  [[ "$INIT" != none ]] || die "未检测到 systemd 或 OpenRC，无法配置开机自启服务"
  log "系统：$PRETTY_NAME；架构：$ARCH；服务管理：$INIT"
}

install_dependencies(){
  log "安装系统依赖（含 cloudflared 运行依赖）..."
  if [[ "$PKG" == apt ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends bash ca-certificates curl wget tar gzip jq openssl python3 iproute2 procps coreutils util-linux dnsutils cron
  else
    apk update
    apk add --no-cache bash ca-certificates curl wget tar gzip jq openssl python3 iproute2 procps coreutils util-linux bind-tools tzdata openrc dcron
  fi
  update-ca-certificates >/dev/null 2>&1 || true
  for c in bash curl tar jq openssl python3; do command_exists "$c" || die "依赖安装后仍缺少命令：$c"; done
  log "系统依赖安装完成"
}

start_scheduler(){
  if [[ "$INIT" == systemd ]]; then
    if command_exists systemctl; then systemctl enable --now cron.service >/dev/null 2>&1 || systemctl enable --now crond.service >/dev/null 2>&1 || true; fi
  else
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
  fi
}

install_cloudflared(){
  if command_exists cloudflared; then
    log "检测到 cloudflared：$(cloudflared --version 2>&1 | head -n1)"
    return 0
  fi
  log "安装 cloudflared..."
  TMP_WORK="$(mktemp -d)"
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  curl -fL --retry 3 --connect-timeout 15 "$url" -o "$TMP_WORK/cloudflared"
  install -m 0755 "$TMP_WORK/cloudflared" /usr/local/bin/cloudflared
  command_exists cloudflared || die "cloudflared 安装失败"
  cloudflared --version | tee -a "$LOG_FILE"
}

create_service_user(){
  if ! grep -q '^suoha:' /etc/group; then
    if [[ "$PKG" == apk ]]; then addgroup -S suoha; else groupadd --system suoha; fi
  fi
  if ! id suoha >/dev/null 2>&1; then
    if [[ "$PKG" == apk ]]; then adduser -S -D -H -G suoha -s /sbin/nologin suoha; else useradd --system --gid suoha --no-create-home --shell /usr/sbin/nologin suoha; fi
  fi
}

install_singbox(){
  if command_exists sing-box && sing-box version 2>/dev/null | grep -q "$SB_VERSION"; then
    log "sing-box 已是目标版本：$SB_VERSION"; return 0
  fi
  log "安装 sing-box $SB_VERSION..."
  TMP_WORK="$(mktemp -d)"
  local archive="sing-box-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${archive}"
  curl -fL --retry 3 --connect-timeout 15 "$url" -o "$TMP_WORK/$archive"
  tar -xzf "$TMP_WORK/$archive" -C "$TMP_WORK"
  local bin
  bin="$(find "$TMP_WORK" -type f -name sing-box -perm -u+x | head -n1)"
  [[ -n "$bin" ]] || die "归档中未找到 sing-box 可执行文件"
  install -m 0755 "$bin" /usr/local/bin/sing-box
  sing-box version | tee -a "$LOG_FILE"
  sing-box generate reality-keypair >/dev/null 2>&1 || die "当前 sing-box 不支持 Reality 密钥生成"
}

rand_hex(){ openssl rand -hex "$1"; }
rand_b64(){ openssl rand -base64 "$1" | tr -d '=+/\n' | cut -c1-32; }
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
port_free(){ ! ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\])$1$"; }

get_public_ip(){
  PUBLIC4="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  PUBLIC6="$(curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
  [[ -n "$PUBLIC4" ]] || PUBLIC4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
  [[ -n "$PUBLIC4" ]] || PUBLIC4="127.0.0.1"
}

issue_certificate(){
  local domain="$1"
  [[ -n "$domain" ]] || die "TLS 协议需要证书域名"
  log "为 $domain 申请 Let's Encrypt 证书（HTTP-01，需要公网 TCP/80 可达，DNS 必须直连源站）..."

  # acme.sh 将程序目录与账户配置目录分开管理。必须显式固定两者，
  # 否则 root 下会退回 /root/.acme.sh，造成安装目录与 account.conf 不一致。
  mkdir -p "$ACME_HOME" "$ACME_CONFIG_HOME"
  chmod 700 "$ACME_HOME" "$ACME_CONFIG_HOME"
  local acme="$ACME_HOME/acme.sh"
  if [[ ! -x "$acme" ]]; then
    curl -fsSL https://get.acme.sh | sh -s --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME"
  fi
  [[ -x "$acme" ]] || die "acme.sh 安装失败：未找到 $acme"

  # 显式指定 Let's Encrypt，并在每次调用时使用同一个 config-home，
  # 不依赖 acme.sh 的 ZeroSSL 默认值，也不要求虚构邮箱地址。
  "$acme" --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" --set-default-ca --server letsencrypt >/dev/null
  "$acme" --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" \
    --issue --server letsencrypt --standalone -d "$domain" --keylength ec-256 --httpport 80
  mkdir -p "$CERT_DIR"
  "$acme" --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" \
    --install-cert -d "$domain" --ecc \
    --key-file "$CERT_DIR/key.pem" \
    --fullchain-file "$CERT_DIR/cert.pem" \
    --reloadcmd "$(command -v true)"
  chmod 600 "$CERT_DIR/key.pem"; chmod 644 "$CERT_DIR/cert.pem"
  [[ -s "$CERT_DIR/key.pem" && -s "$CERT_DIR/cert.pem" ]] || die "证书文件不存在或为空"
  if command_exists crontab; then
    (crontab -l 2>/dev/null | grep -v 'suoha-v2-acme-renew' || true
     echo "17 3 * * * $acme --home $ACME_HOME --config-home $ACME_CONFIG_HOME --cron >/dev/null 2>&1 && (systemctl restart suoha-v2 2>/dev/null || rc-service suoha-v2 restart 2>/dev/null || true) # suoha-v2-acme-renew") | crontab -
  fi
}

make_credentials(){
  mkdir -p "$ETC" "$CERT_DIR" "$SUB_DIR"
  chmod 700 "$ETC" "$CERT_DIR" "$SUB_DIR"
  if [[ -f "$CREDENTIALS" ]]; then
    warn "发现已有凭证，保留现有凭证，不覆盖"
    # shellcheck disable=SC1090
    source "$CREDENTIALS"
    if [[ -z "${VMESS_UUID:-}" ]]; then VMESS_UUID="$(sing-box generate uuid)"; printf "\nVMESS_UUID='%s'\n" "$VMESS_UUID" >> "$CREDENTIALS"; fi
  else
    UUID="$(sing-box generate uuid)"
    REALITY_KEYS="$(sing-box generate reality-keypair)"
    REALITY_PRIVATE="$(awk '/PrivateKey/{print $2}' <<<"$REALITY_KEYS")"
    REALITY_PUBLIC="$(awk '/PublicKey/{print $2}' <<<"$REALITY_KEYS")"
    [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || die "Reality 密钥生成失败：$REALITY_KEYS"
    REALITY_SID="$(rand_hex 4)"
    HY2_PASS="$(rand_b64 24)"; HY2_OBFS="$(rand_b64 24)"
    TUIC_UUID="$(sing-box generate uuid)"; TUIC_PASS="$(rand_b64 24)"
    ANYTLS_PASS="$(rand_b64 24)"; TROJAN_PASS="$(rand_b64 24)"
    SNELL_PSK="$(rand_b64 24)"; VMESS_UUID="$(sing-box generate uuid)"
    umask 077
    cat > "$CREDENTIALS" <<EOF_CRED
UUID='$UUID'
REALITY_PRIVATE='$REALITY_PRIVATE'
REALITY_PUBLIC='$REALITY_PUBLIC'
REALITY_SID='$REALITY_SID'
HY2_PASS='$HY2_PASS'
HY2_OBFS='$HY2_OBFS'
TUIC_UUID='$TUIC_UUID'
TUIC_PASS='$TUIC_PASS'
ANYTLS_PASS='$ANYTLS_PASS'
TROJAN_PASS='$TROJAN_PASS'
SNELL_PSK='$SNELL_PSK'
VMESS_UUID='$VMESS_UUID'
EOF_CRED
    chmod 600 "$CREDENTIALS"
  fi
  REALITY_GRPC_SERVICE="gr-$(rand_hex 6)"
  SS6_PASSWORD="$(rand_b64 24)"
}

ask_config(){
  echo
  echo "请选择连接 / 域名模式："
  echo "  1) 直连：公网 IP / 自定义域名直连（推荐代理数据面）"
  echo "  2) Cloudflare 临时 Tunnel：发布订阅 + Argo WebSocket 节点（域名可能变化）"
  echo "  3) Cloudflare Named Tunnel：发布订阅 + Argo WebSocket 节点（自定义域名）"
  read -r -p "选择 [1-3，默认 1]：" TUNNEL_MODE; TUNNEL_MODE="${TUNNEL_MODE:-1}"
  [[ "$TUNNEL_MODE" =~ ^[123]$ ]] || die "无效的模式选择"

  read -r -p "代理连接域名（建议 DNS only，A/AAAA 指向本机；留空则仅 Reality/Snell 用 IP）：" PROXY_DOMAIN
  if [[ -n "$PROXY_DOMAIN" ]]; then valid_domain "$PROXY_DOMAIN" || die "域名格式不正确"; fi
  if [[ -n "$PROXY_DOMAIN" ]]; then issue_certificate "$PROXY_DOMAIN"; else
    warn "未提供代理域名：将不启用需要可信 TLS 证书的 Hysteria2/TUIC/AnyTLS/Trojan。"
  fi
  get_public_ip
  if [[ "$PUBLIC4" == 127.* && -z "$PUBLIC6" ]]; then die "无法检测公网 IP，请检查网络后重试"; fi
  read -r -p "VLESS Reality Vision TCP 端口 [4433]：" P_REALITY; P_REALITY="${P_REALITY:-4433}"
  read -r -p "VLESS Reality gRPC TCP 端口 [4434]：" P_REALITY_GRPC; P_REALITY_GRPC="${P_REALITY_GRPC:-4434}"
  read -r -p "Hysteria2 UDP 端口 [8443]：" P_HY2; P_HY2="${P_HY2:-8443}"
  read -r -p "TUIC UDP 端口 [8444]：" P_TUIC; P_TUIC="${P_TUIC:-8444}"
  read -r -p "AnyTLS TCP 端口 [8445]：" P_ANYTLS; P_ANYTLS="${P_ANYTLS:-8445}"
  read -r -p "Snell TCP 端口 [8446]：" P_SNELL; P_SNELL="${P_SNELL:-8446}"
  read -r -p "Trojan TCP 端口 [8447]：" P_TROJAN; P_TROJAN="${P_TROJAN:-8447}"
  local ports=("$P_REALITY" "$P_REALITY_GRPC" "$P_HY2" "$P_TUIC" "$P_ANYTLS" "$P_SNELL" "$P_TROJAN")
  local seen=" "
  for p in "${ports[@]}"; do
    valid_port "$p" || die "端口无效：$p"
    [[ "$seen" != *" $p "* ]] || die "端口重复：$p"
    seen+="$p "
    if ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\])${p}$"; then die "端口已被占用：$p"; fi
  done
  if [[ -n "$PROXY_DOMAIN" ]]; then NODE_HOST="$PROXY_DOMAIN"; elif [[ "$PUBLIC4" != 127.* ]]; then NODE_HOST="$PUBLIC4"; else NODE_HOST="$PUBLIC6"; fi
  read -r -p "Shadowsocks IPv6 TCP 端口 [8448]：" P_SS6; P_SS6="${P_SS6:-8448}"
  valid_port "$P_SS6" || die "Shadowsocks IPv6 端口无效"
  [[ "$seen" != *" $P_SS6 "* ]] || die "Shadowsocks 端口与其他端口重复：$P_SS6"
  if ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\])${P_SS6}$"; then die "Shadowsocks IPv6 端口已被占用：$P_SS6"; fi

  SUB_PORT=18080
  SUB_TOKEN="$(rand_hex 24)"
  if [[ "$TUNNEL_MODE" == 1 && -n "$PROXY_DOMAIN" ]]; then SUB_TLS=1; SUB_HOST=0.0.0.0; else SUB_TLS=0; SUB_HOST=127.0.0.1; fi
  ARGO_ENABLED=0
  ARGO_HOST=""
  ARGO_OPT_IPS=""
  ARGO_VLESS_PATH="/vl-$(rand_hex 8)"
  ARGO_TROJAN_PATH="/tr-$(rand_hex 8)"
  ARGO_VMESS_PATH="/vm-$(rand_hex 8)"
  if [[ "$TUNNEL_MODE" != 1 ]]; then
    ARGO_ENABLED=1
    if [[ "$TUNNEL_MODE" == 3 ]]; then
      read -r -p "Cloudflare 订阅域名（例如 sub.example.com）：" SUB_DOMAIN
      valid_domain "$SUB_DOMAIN" || die "订阅域名格式不正确"
      read -r -p "Argo 节点域名（可与订阅域名相同，默认相同）：" ARGO_DOMAIN
      ARGO_DOMAIN="${ARGO_DOMAIN:-$SUB_DOMAIN}"
      valid_domain "$ARGO_DOMAIN" || die "Argo 域名格式不正确"
      ARGO_HOST="$ARGO_DOMAIN"
    fi
    echo "Argo 将生成 VLESS-WS、Trojan-WS、VMess-WS 三类节点。"
    echo "默认加入 Cloudflare Anycast 候选 IP，由 Clash/Mihomo 在客户端网络自动测速；也可追加自定义 IPv4。"
    read -r -p "自定义优选 IPv4（逗号分隔，可留空）：" ARGO_OPT_IPS
    local opt_ip
    IFS=',' read -r -a opt_check <<< "$ARGO_OPT_IPS"
    for opt_ip in "${opt_check[@]}"; do
      opt_ip="$(printf '%s' "$opt_ip" | xargs)"
      [[ -z "$opt_ip" ]] && continue
      python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if ip.version == 4 else 1)' "$opt_ip" || die "优选地址不是有效 IPv4：$opt_ip"
    done
    local reserved_seen="$seen $P_SS6 "
    for p in "$ARGO_ROUTER_PORT" "$SUB_PORT" "$ARGO_VLESS_PORT" "$ARGO_TROJAN_PORT" "$ARGO_VMESS_PORT"; do
      [[ "$reserved_seen" != *" $p "* ]] || die "Argo/订阅端口与代理端口重复：$p"
      if ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(:|\])${p}$"; then die "Argo/订阅端口已被占用：$p"; fi
      reserved_seen+="$p "
    done
  else
    SUB_DOMAIN=""
    ARGO_DOMAIN=""
  fi
}

build_config(){
  local cert="$CERT_DIR/cert.pem" key="$CERT_DIR/key.pem"
  local tls='null'
  if [[ -n "$PROXY_DOMAIN" ]]; then tls="$(jq -cn --arg c "$cert" --arg k "$key" '{enabled:true,certificate_path:$c,key_path:$k}')"; fi
  local inbounds='[]'
  local add
  add="$(jq -cn --argjson p "$P_REALITY" --arg u "$UUID" --arg pk "$REALITY_PRIVATE" --arg sid "$REALITY_SID" '{type:"vless",tag:"vless-reality",listen:"::",listen_port:$p,users:[{uuid:$u,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:"www.microsoft.com",reality:{enabled:true,handshake:{server:"www.microsoft.com",server_port:443},private_key:$pk,short_id:[$sid]}}}')"
  inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
  add="$(jq -cn --argjson p "$P_REALITY_GRPC" --arg u "$UUID" --arg pk "$REALITY_PRIVATE" --arg sid "$REALITY_SID" --arg service "$REALITY_GRPC_SERVICE" '{type:"vless",tag:"vless-reality-grpc",listen:"::",listen_port:$p,users:[{uuid:$u}],tls:{enabled:true,server_name:"www.microsoft.com",reality:{enabled:true,handshake:{server:"www.microsoft.com",server_port:443},private_key:$pk,short_id:[$sid]}},transport:{type:"grpc",service_name:$service}}')"
  inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
  if [[ -n "$PUBLIC6" ]]; then
    add="$(jq -cn --argjson p "$P_SS6" --arg pass "$SS6_PASSWORD" '{type:"shadowsocks",tag:"shadowsocks-ipv6",listen:"::",listen_port:$p,method:"aes-128-gcm",password:$pass}')"
    inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
  fi
  if [[ -n "$PROXY_DOMAIN" ]]; then
    add="$(jq -cn --argjson p "$P_HY2" --arg c "$cert" --arg k "$key" --arg pass "$HY2_PASS" --arg obfs "$HY2_OBFS" '{type:"hysteria2",tag:"hysteria2",listen:"::",listen_port:$p,users:[{password:$pass}],obfs:{type:"salamander",password:$obfs},tls:{enabled:true,certificate_path:$c,key_path:$k,alpn:["h3"]}}')"; inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
    add="$(jq -cn --argjson p "$P_TUIC" --arg c "$cert" --arg k "$key" --arg u "$TUIC_UUID" --arg pass "$TUIC_PASS" '{type:"tuic",tag:"tuic",listen:"::",listen_port:$p,users:[{uuid:$u,password:$pass}],congestion_control:"bbr",zero_rtt_handshake:false,tls:{enabled:true,certificate_path:$c,key_path:$k,alpn:["h3"]}}')"; inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
    add="$(jq -cn --argjson p "$P_ANYTLS" --arg c "$cert" --arg k "$key" --arg pass "$ANYTLS_PASS" '{type:"anytls",tag:"anytls",listen:"::",listen_port:$p,users:[{password:$pass}],tls:{enabled:true,certificate_path:$c,key_path:$k}}')"; inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
    add="$(jq -cn --argjson p "$P_TROJAN" --arg c "$cert" --arg k "$key" --arg pass "$TROJAN_PASS" '{type:"trojan",tag:"trojan",listen:"::",listen_port:$p,users:[{password:$pass}],tls:{enabled:true,certificate_path:$c,key_path:$k}}')"; inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
  fi
  add="$(jq -cn --argjson p "$P_SNELL" --arg psk "$SNELL_PSK" '{type:"snell",tag:"snell",listen:"::",listen_port:$p,version:5,psk:$psk,obfs_mode:"http"}')"; inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
  if [[ "${ARGO_ENABLED:-0}" == 1 ]]; then
    add="$(jq -cn --argjson p "$ARGO_VLESS_PORT" --arg u "$UUID" --arg path "$ARGO_VLESS_PATH" '{type:"vless",tag:"argo-vless-ws",listen:"127.0.0.1",listen_port:$p,users:[{uuid:$u}],transport:{type:"ws",path:$path}}')"; inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
    add="$(jq -cn --argjson p "$ARGO_TROJAN_PORT" --arg pass "$TROJAN_PASS" --arg path "$ARGO_TROJAN_PATH" '{type:"trojan",tag:"argo-trojan-ws",listen:"127.0.0.1",listen_port:$p,users:[{password:$pass}],transport:{type:"ws",path:$path}}')"; inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
    add="$(jq -cn --argjson p "$ARGO_VMESS_PORT" --arg u "$VMESS_UUID" --arg path "$ARGO_VMESS_PATH" '{type:"vmess",tag:"argo-vmess-ws",listen:"127.0.0.1",listen_port:$p,users:[{uuid:$u,alterId:0}],transport:{type:"ws",path:$path}}')"; inbounds="$(jq -cn --argjson a "$inbounds" --argjson b "$add" '$a+[$b]')"
  fi
  jq -n --argjson inbounds "$inbounds" '{log:{level:"info",timestamp:true},inbounds:$inbounds,outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' > "$SB_CONFIG.tmp"
  sing-box check -c "$SB_CONFIG.tmp" || die "sing-box 配置校验失败，旧配置保持不变"
  install -o root -g suoha -m 640 "$SB_CONFIG.tmp" "$SB_CONFIG"; rm -f "$SB_CONFIG.tmp"
  chown root:suoha "$ETC" "$CERT_DIR"; chmod 750 "$ETC" "$CERT_DIR"
  chown root:suoha "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem" 2>/dev/null || true
  chmod 640 "$CERT_DIR/key.pem" 2>/dev/null || true
  cat > "$ETC/settings.env" <<EOF_SETTINGS
PROXY_DOMAIN='$PROXY_DOMAIN'
NODE_HOST='$NODE_HOST'
PUBLIC4='$PUBLIC4'
PUBLIC6='$PUBLIC6'
P_REALITY='$P_REALITY'
P_REALITY_GRPC='$P_REALITY_GRPC'
REALITY_GRPC_SERVICE='$REALITY_GRPC_SERVICE'
P_SS6='$P_SS6'
SS6_PASSWORD='$SS6_PASSWORD'
P_HY2='$P_HY2'
P_TUIC='$P_TUIC'
P_ANYTLS='$P_ANYTLS'
P_SNELL='$P_SNELL'
P_TROJAN='$P_TROJAN'
TUNNEL_MODE='$TUNNEL_MODE'
SUB_PORT='$SUB_PORT'
SUB_TOKEN='$SUB_TOKEN'
SUB_TLS='$SUB_TLS'
SUB_HOST='$SUB_HOST'
SUB_DOMAIN='${SUB_DOMAIN:-}'
ARGO_ENABLED='${ARGO_ENABLED:-0}'
ARGO_DOMAIN='${ARGO_DOMAIN:-}'
ARGO_HOST='${ARGO_HOST:-}'
ARGO_OPT_IPS='${ARGO_OPT_IPS:-}'
ARGO_ROUTER_PORT='$ARGO_ROUTER_PORT'
ARGO_VLESS_PORT='$ARGO_VLESS_PORT'
ARGO_TROJAN_PORT='$ARGO_TROJAN_PORT'
ARGO_VMESS_PORT='$ARGO_VMESS_PORT'
ARGO_VLESS_PATH='$ARGO_VLESS_PATH'
ARGO_TROJAN_PATH='$ARGO_TROJAN_PATH'
ARGO_VMESS_PATH='$ARGO_VMESS_PATH'
EOF_SETTINGS
  chmod 600 "$ETC/settings.env"
}

write_subscription(){
  # shellcheck disable=SC1090
  source "$CREDENTIALS"; source "$ETC/settings.env"
  local host="$NODE_HOST" enc_host="$NODE_HOST" lines="" vmess_json vmess_b64 ss_auth ss_b64
  local server label n1 n2 n3
  local all_names=() argo_names=() servers=() opt opt_array=()
  [[ "$host" == *:* ]] && enc_host="[$host]"
  : > "$SUB_DIR/nodes.txt"
  : > "$SUB_DIR/surge.conf"
  cat > "$SUB_DIR/clash.yaml" <<'EOF_CLASH_BASE'
# Suoha V2 full node list for Mihomo / Clash Meta
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
proxies:
EOF_CLASH_BASE

  # Direct VLESS Reality Vision
  lines+="vless://${UUID}@${enc_host}:${P_REALITY}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=tcp&flow=xtls-rprx-vision#Suoha-VLESS-Reality-Vision\\n"
  n1="Suoha-VLESS-Reality-Vision"; all_names+=("$n1")
  cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: vless
    server: "$host"
    port: $P_REALITY
    uuid: "$UUID"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.microsoft.com
    reality-opts:
      public-key: "$REALITY_PUBLIC"
      short-id: "$REALITY_SID"
    client-fingerprint: chrome
EOF_CLASH_DIRECT

  # Direct VLESS Reality gRPC
  lines+="vless://${UUID}@${enc_host}:${P_REALITY_GRPC}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=grpc&serviceName=${REALITY_GRPC_SERVICE}#Suoha-VLESS-Reality-gRPC\\n"
  n1="Suoha-VLESS-Reality-gRPC"; all_names+=("$n1")
  cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: vless
    server: "$host"
    port: $P_REALITY_GRPC
    uuid: "$UUID"
    network: grpc
    tls: true
    udp: true
    servername: www.microsoft.com
    grpc-opts:
      grpc-service-name: "$REALITY_GRPC_SERVICE"
    reality-opts:
      public-key: "$REALITY_PUBLIC"
      short-id: "$REALITY_SID"
    client-fingerprint: chrome
EOF_CLASH_DIRECT

  # Snell direct: sing-box server v5 is wire-compatible with client v4 (QUIC mode is not used).
  if [[ "$PUBLIC4" != 127.* && -n "$PUBLIC4" ]]; then
    lines+="snell://${SNELL_PSK}@${PUBLIC4}:${P_SNELL}?version=4&obfs=http#Suoha-Snell-IPv4\\n"
    n1="Suoha-Snell-IPv4"; all_names+=("$n1")
    cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: snell
    server: "$PUBLIC4"
    port: $P_SNELL
    psk: "$SNELL_PSK"
    version: 4
    udp: true
EOF_CLASH_DIRECT
    printf '%s = snell, %s, %s, psk=%s, version=4, reuse=true\n' "$n1" "$PUBLIC4" "$P_SNELL" "$SNELL_PSK" >> "$SUB_DIR/surge.conf"
  fi
  if [[ -n "$PUBLIC6" ]]; then
    lines+="snell://${SNELL_PSK}@[${PUBLIC6}]:${P_SNELL}?version=4&obfs=http#Suoha-Snell-IPv6\\n"
    n1="Suoha-Snell-IPv6"; all_names+=("$n1")
    cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: snell
    server: "$PUBLIC6"
    port: $P_SNELL
    psk: "$SNELL_PSK"
    version: 4
    udp: true
EOF_CLASH_DIRECT
    printf '%s = snell, [%s], %s, psk=%s, version=4, reuse=true\n' "$n1" "$PUBLIC6" "$P_SNELL" "$SNELL_PSK" >> "$SUB_DIR/surge.conf"
    ss_auth="aes-128-gcm:${SS6_PASSWORD}"
    ss_b64="$(printf '%s' "$ss_auth" | base64 | tr -d '\n')"
    lines+="ss://${ss_b64}@[${PUBLIC6}]:${P_SS6}#Suoha-SS-IPv6\\n"
    n1="Suoha-SS-IPv6"; all_names+=("$n1")
    cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: ss
    server: "$PUBLIC6"
    port: $P_SS6
    cipher: aes-128-gcm
    password: "$SS6_PASSWORD"
    udp: true
EOF_CLASH_DIRECT
  fi

  if [[ -n "$PROXY_DOMAIN" ]]; then
    lines+="hysteria2://${HY2_PASS}@${PROXY_DOMAIN}:${P_HY2}?sni=${PROXY_DOMAIN}&obfs=salamander&obfs-password=${HY2_OBFS}#Suoha-Hysteria2\\n"
    n1="Suoha-Hysteria2"; all_names+=("$n1")
    cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: hysteria2
    server: "$PROXY_DOMAIN"
    port: $P_HY2
    password: "$HY2_PASS"
    sni: "$PROXY_DOMAIN"
    obfs: salamander
    obfs-password: "$HY2_OBFS"
EOF_CLASH_DIRECT
    lines+="tuic://${TUIC_UUID}:${TUIC_PASS}@${PROXY_DOMAIN}:${P_TUIC}?congestion_control=bbr&udp_relay_mode=native&sni=${PROXY_DOMAIN}&alpn=h3#Suoha-TUIC\\n"
    n1="Suoha-TUIC"; all_names+=("$n1")
    cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: tuic
    server: "$PROXY_DOMAIN"
    port: $P_TUIC
    uuid: "$TUIC_UUID"
    password: "$TUIC_PASS"
    congestion-controller: bbr
    udp-relay-mode: native
    sni: "$PROXY_DOMAIN"
    alpn: [h3]
EOF_CLASH_DIRECT
    lines+="anytls://${ANYTLS_PASS}@${PROXY_DOMAIN}:${P_ANYTLS}?sni=${PROXY_DOMAIN}&insecure=0#Suoha-AnyTLS\\n"
    n1="Suoha-AnyTLS"; all_names+=("$n1")
    cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: anytls
    server: "$PROXY_DOMAIN"
    port: $P_ANYTLS
    password: "$ANYTLS_PASS"
    sni: "$PROXY_DOMAIN"
EOF_CLASH_DIRECT
    lines+="trojan://${TROJAN_PASS}@${PROXY_DOMAIN}:${P_TROJAN}?security=tls&sni=${PROXY_DOMAIN}&type=tcp#Suoha-Trojan-TLS\\n"
    n1="Suoha-Trojan-TLS"; all_names+=("$n1")
    cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_DIRECT
  - name: "$n1"
    type: trojan
    server: "$PROXY_DOMAIN"
    port: $P_TROJAN
    password: "$TROJAN_PASS"
    sni: "$PROXY_DOMAIN"
EOF_CLASH_DIRECT
  fi

  if [[ "${ARGO_ENABLED:-0}" == 1 && -n "${ARGO_HOST:-}" ]]; then
    # Official Cloudflare anycast candidates; Mihomo URL-test selects from the user's actual network.
    servers=("$ARGO_HOST" "104.16.0.1" "104.17.0.1" "104.18.0.1" "104.19.0.1" "172.64.0.1" "172.65.0.1" "188.114.96.1" "188.114.97.1")
    IFS=',' read -r -a opt_array <<< "${ARGO_OPT_IPS:-}"
    for opt in "${opt_array[@]}"; do
      opt="$(printf '%s' "$opt" | xargs)"
      [[ -z "$opt" ]] && continue
      case " ${servers[*]} " in *" $opt "*) continue ;; esac
      servers+=("$opt")
    done
    for server in "${servers[@]}"; do
      if [[ "$server" == "$ARGO_HOST" ]]; then label="Default"; else label="CF-${server}"; fi
      n1="Suoha-VLESS-Argo-${label}"; n2="Suoha-Trojan-Argo-${label}"; n3="Suoha-VMess-Argo-${label}"
      all_names+=("$n1" "$n2" "$n3"); argo_names+=("$n1" "$n2" "$n3")
      lines+="vless://${UUID}@${server}:443?encryption=none&security=tls&sni=${ARGO_HOST}&type=ws&host=${ARGO_HOST}&path=%2F${ARGO_VLESS_PATH#/}#${n1}\\n"
      lines+="trojan://${TROJAN_PASS}@${server}:443?security=tls&sni=${ARGO_HOST}&type=ws&host=${ARGO_HOST}&path=%2F${ARGO_TROJAN_PATH#/}#${n2}\\n"
      vmess_json="$(jq -cn --arg ps "$n3" --arg add "$server" --arg id "$VMESS_UUID" --arg host "$ARGO_HOST" --arg path "$ARGO_VMESS_PATH" '{v:"2",ps:$ps,add:$add,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
      vmess_b64="$(printf '%s' "$vmess_json" | base64 | tr -d '\n')"
      lines+="vmess://${vmess_b64}\\n"
      cat >> "$SUB_DIR/clash.yaml" <<EOF_CLASH_ARGO
  - name: "$n1"
    type: vless
    server: "$server"
    port: 443
    uuid: "$UUID"
    network: ws
    tls: true
    servername: "$ARGO_HOST"
    ws-opts:
      path: "$ARGO_VLESS_PATH"
      headers:
        Host: "$ARGO_HOST"
  - name: "$n2"
    type: trojan
    server: "$server"
    port: 443
    password: "$TROJAN_PASS"
    sni: "$ARGO_HOST"
    network: ws
    ws-opts:
      path: "$ARGO_TROJAN_PATH"
      headers:
        Host: "$ARGO_HOST"
  - name: "$n3"
    type: vmess
    server: "$server"
    port: 443
    uuid: "$VMESS_UUID"
    alterId: 0
    cipher: auto
    tls: true
    servername: "$ARGO_HOST"
    network: ws
    ws-opts:
      path: "$ARGO_VMESS_PATH"
      headers:
        Host: "$ARGO_HOST"
EOF_CLASH_ARGO
    done
  fi

  printf '%b' "$lines" > "$SUB_DIR/nodes.txt"
  {
    echo 'proxy-groups:'
    if ((${#argo_names[@]})); then
      echo '  - name: Argo-Auto'
      echo '    type: url-test'
      echo '    url: https://www.gstatic.com/generate_204'
      echo '    interval: 300'
      echo '    tolerance: 80'
      echo '    proxies:'
      for n1 in "${argo_names[@]}"; do printf '      - "%s"\n' "$n1"; done
    fi
    echo '  - name: PROXY'
    echo '    type: select'
    echo '    proxies:'
    if ((${#argo_names[@]})); then echo '      - Argo-Auto'; fi
    for n1 in "${all_names[@]}"; do printf '      - "%s"\n' "$n1"; done
    echo 'rules:'
    echo '  - MATCH,PROXY'
  } >> "$SUB_DIR/clash.yaml"
  base64 "$SUB_DIR/nodes.txt" | tr -d '\n' > "$SUB_DIR/sub.txt"
  chown root:suoha "$SUB_DIR" "$SUB_DIR"/*
  chmod 750 "$SUB_DIR"
  chmod 640 "$SUB_DIR"/*
}
write_sub_server(){
  cat > "$SUB_SERVER" <<'PY_SUB'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import os
TOKEN = os.environ['SUB_TOKEN']
ROOT = Path('/etc/suoha-v2/subscription')
ALLOWED = {'sub.txt', 'nodes.txt', 'clash.yaml', 'surge.conf'}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        prefix = '/' + TOKEN + '/'
        if not path.startswith(prefix):
            self.send_error(404); return
        name = path[len(prefix):]
        if name not in ALLOWED:
            self.send_error(404); return
        p = ROOT / name
        if not p.is_file():
            self.send_error(404); return
        data = p.read_bytes()
        content_type = 'text/plain; charset=utf-8'
        if name.endswith('.yaml') or name.endswith('.conf'):
            content_type = 'text/plain; charset=utf-8'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass
srv = ThreadingHTTPServer((os.environ.get('SUB_HOST', '127.0.0.1'), int(os.environ.get('SUB_PORT', '18080'))), H)
srv.daemon_threads = True
if os.environ.get('SUB_TLS') == '1':
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain('/etc/suoha-v2/cert/cert.pem', '/etc/suoha-v2/cert/key.pem')
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY_SUB
  chown root:suoha "$SUB_SERVER"
  chmod 640 "$SUB_SERVER"
}
service_unit(){
  if [[ "$INIT" == systemd ]]; then
    cat > /etc/systemd/system/suoha-v2.service <<EOF_SB_UNIT
[Unit]
Description=Suoha V2 sing-box service
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=suoha
Group=suoha
ExecStart=/usr/local/bin/sing-box run -c $SB_CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
EOF_SB_UNIT
    systemctl daemon-reload; systemctl enable --now suoha-v2
  else
    cat > /etc/init.d/suoha-v2 <<'EOF_SB_RC'
#!/sbin/openrc-run
description="Suoha V2 sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/suoha-v2/config.json"
command_user="suoha:suoha"
command_background="yes"
pidfile="/run/suoha-v2.pid"
output_log="/var/log/suoha-v2/sing-box.log"
error_log="/var/log/suoha-v2/sing-box.err"
EOF_SB_RC
    chmod +x /etc/init.d/suoha-v2; rc-update add suoha-v2 default; rc-service suoha-v2 restart
  fi
}

sub_service(){
  # shellcheck disable=SC1090
  source "$ETC/settings.env"
  write_sub_server
  if [[ "$INIT" == systemd ]]; then
    cat > /etc/systemd/system/suoha-sub.service <<EOF_SUB_UNIT
[Unit]
Description=Suoha V2 token protected subscription endpoint
After=network-online.target
[Service]
Type=simple
EnvironmentFile=$ETC/sub.env
ExecStart=/usr/bin/python3 $SUB_SERVER
Restart=on-failure
User=suoha
Group=suoha
NoNewPrivileges=true
ProtectSystem=strict
ReadOnlyPaths=$SUB_DIR
[Install]
WantedBy=multi-user.target
EOF_SUB_UNIT
    printf 'SUB_TOKEN=%s\nSUB_PORT=%s\nSUB_TLS=%s\nSUB_HOST=%s\n' "$SUB_TOKEN" "$SUB_PORT" "$SUB_TLS" "$SUB_HOST" > "$ETC/sub.env"
    chown root:suoha "$ETC/sub.env"; chmod 640 "$ETC/sub.env"
    systemctl daemon-reload; systemctl enable --now suoha-sub
  else
    cat > /etc/init.d/suoha-sub <<'EOF_SUB_RC'
#!/sbin/openrc-run
description="Suoha V2 subscription endpoint"
command="/usr/bin/python3"
command_args="/etc/suoha-v2/sub_server.py"
command_user="suoha:suoha"
command_background="yes"
pidfile="/run/suoha-sub.pid"
output_log="/var/log/suoha-v2/sub.log"
error_log="/var/log/suoha-v2/sub.err"
EOF_SUB_RC
    # OpenRC env file keeps token outside the init script
    printf 'SUB_TOKEN="%s"\nSUB_PORT="%s"\nSUB_TLS="%s"\nSUB_HOST="%s"\n' "$SUB_TOKEN" "$SUB_PORT" "$SUB_TLS" "$SUB_HOST" > /etc/conf.d/suoha-sub
    chmod 600 /etc/conf.d/suoha-sub
    rc-update add suoha-sub default; rc-service suoha-sub restart
  fi
}


write_argo_router(){
  [[ "${ARGO_ENABLED:-0}" == 1 ]] || return 0
  source "$ETC/settings.env"
  cat > "$ARGO_ROUTER" <<PY_ROUTER
#!/usr/bin/env python3
import asyncio
ROUTES = {
    "${ARGO_VLESS_PATH}": ${ARGO_VLESS_PORT},
    "${ARGO_TROJAN_PATH}": ${ARGO_TROJAN_PORT},
    "${ARGO_VMESS_PATH}": ${ARGO_VMESS_PORT},
    "/${SUB_TOKEN}/sub.txt": ${SUB_PORT},
    "/${SUB_TOKEN}/nodes.txt": ${SUB_PORT},
    "/${SUB_TOKEN}/clash.yaml": ${SUB_PORT},
    "/${SUB_TOKEN}/surge.conf": ${SUB_PORT},
}
async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data: break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        try: writer.close()
        except Exception: pass
async def handle(client_r, client_w):
    upstream_w = None
    try:
        head = await asyncio.wait_for(client_r.readuntil(b"\r\n\r\n"), 12)
        first = head.split(b"\r\n", 1)[0].decode("latin1", "replace")
        parts = first.split(" ")
        if len(parts) < 2: raise ValueError("bad request")
        path = parts[1].split("?", 1)[0]
        target = next((port for prefix, port in ROUTES.items() if path == prefix or path.startswith(prefix + "/")), None)
        if target is None: raise ValueError("unknown path")
        upstream_r, upstream_w = await asyncio.open_connection("127.0.0.1", target)
        upstream_w.write(head); await upstream_w.drain()
        tasks = [asyncio.create_task(pipe(client_r, upstream_w)), asyncio.create_task(pipe(upstream_r, client_w))]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending: task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    except Exception:
        try:
            client_w.write(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            await client_w.drain()
        except Exception: pass
    finally:
        try: client_w.close()
        except Exception: pass
async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", ${ARGO_ROUTER_PORT}, limit=131072)
    async with server: await server.serve_forever()
asyncio.run(main())
PY_ROUTER
  chown root:suoha "$ARGO_ROUTER"
  chmod 640 "$ARGO_ROUTER"
}

argo_router_service(){
  [[ "${ARGO_ENABLED:-0}" == 1 ]] || return 0
  write_argo_router
  if [[ "$INIT" == systemd ]]; then
    cat > /etc/systemd/system/suoha-argo-router.service <<EOF_AR
[Unit]
Description=Suoha V2 Argo WebSocket path router
After=network-online.target suoha-v2.service suoha-sub.service
Requires=suoha-v2.service suoha-sub.service
[Service]
Type=simple
User=suoha
Group=suoha
ExecStart=/usr/bin/python3 $ARGO_ROUTER
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
EOF_AR
    systemctl daemon-reload; systemctl enable --now suoha-argo-router
  else
    cat > /etc/init.d/suoha-argo-router <<EOF_AR_RC
#!/sbin/openrc-run
description="Suoha V2 Argo WebSocket path router"
command="/usr/bin/python3"
command_args="$ARGO_ROUTER"
command_user="suoha:suoha"
command_background="yes"
pidfile="/run/suoha-argo-router.pid"
output_log="$LOG_DIR/argo-router.log"
error_log="$LOG_DIR/argo-router.err"
EOF_AR_RC
    chmod +x /etc/init.d/suoha-argo-router
    rc-update add suoha-argo-router default
    rc-service suoha-argo-router restart
  fi
}

cloudflared_tunnel(){
  # shellcheck disable=SC1090
  source "$ETC/settings.env"
  [[ "$TUNNEL_MODE" == 1 ]] && { log "选择直连模式：不创建 Cloudflare Tunnel"; return 0; }
  install_cloudflared
  if [[ "$TUNNEL_MODE" == 2 ]]; then
    log "启动 Cloudflare 临时 Tunnel（订阅 + Argo WebSocket；URL 每次重建可能变化）..."
    if [[ "$INIT" == systemd ]]; then
      cat > /etc/systemd/system/suoha-tunnel.service <<EOF_QS
[Unit]
Description=Suoha V2 Cloudflare Quick Tunnel (subscription and Argo WS)
After=network-online.target suoha-sub.service suoha-argo-router.service
Requires=suoha-sub.service suoha-argo-router.service
[Service]
Type=simple
ExecStartPre=/usr/bin/truncate -s 0 $LOG_DIR/cloudflared.log
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$ARGO_ROUTER_PORT
ExecStartPost=/usr/local/bin/suoha-v2 refresh
Restart=always
RestartSec=5
StandardOutput=append:$LOG_DIR/cloudflared.log
StandardError=append:$LOG_DIR/cloudflared.log
[Install]
WantedBy=multi-user.target
EOF_QS
      systemctl daemon-reload; systemctl enable --now suoha-tunnel
    else
      cat > /etc/init.d/suoha-tunnel <<EOF_QR
#!/sbin/openrc-run
description="Suoha V2 Cloudflare Quick Tunnel"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate --url http://127.0.0.1:$ARGO_ROUTER_PORT"
command_background="yes"
start_pre() { : > "$LOG_DIR/cloudflared.log"; }
start_post() { /usr/local/bin/suoha-v2 refresh; }
pidfile="/run/suoha-tunnel.pid"
output_log="$LOG_DIR/cloudflared.log"
error_log="$LOG_DIR/cloudflared.err"
EOF_QR
      chmod +x /etc/init.d/suoha-tunnel; rc-update add suoha-tunnel default; rc-service suoha-tunnel restart
    fi
    local quick_host=""
    for _ in $(seq 1 60); do
      quick_host="$(grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | tail -n1 | sed 's#https://##')"
      [[ -n "$quick_host" ]] && break
      sleep 1
    done
    [[ -n "$quick_host" ]] || die "Quick Tunnel 未能获取公网域名；请检查 $LOG_DIR/cloudflared.log"
    ARGO_HOST="$quick_host"
    sed -i "s|^ARGO_HOST=.*|ARGO_HOST='$ARGO_HOST'|" "$ETC/settings.env"
    log "Quick Tunnel 已启动：$ARGO_HOST"
  else
    log "Named Tunnel：需要交互式 Cloudflare 授权。"
    cloudflared tunnel login
    local name="suoha-v2"
    if ! cloudflared tunnel list | awk 'NR>1{print $2}' | grep -Fxq "$name"; then cloudflared tunnel create "$name"; fi
    local tid; tid="$(cloudflared tunnel list | awk -v n="$name" '$2==n{print $1;exit}')"
    [[ -n "$tid" ]] || die "无法找到 Named Tunnel ID"
    cloudflared tunnel route dns "$name" "$SUB_DOMAIN"
    if [[ "$ARGO_DOMAIN" != "$SUB_DOMAIN" ]]; then cloudflared tunnel route dns "$name" "$ARGO_DOMAIN"; fi
    mkdir -p /root/.cloudflared
      if [[ "$ARGO_DOMAIN" == "$SUB_DOMAIN" ]]; then
      cat > "$ETC/cloudflared.yml" <<EOF_CF
 tunnel: $tid
 credentials-file: /root/.cloudflared/$tid.json
 ingress:
   - hostname: $SUB_DOMAIN
     service: http://127.0.0.1:$ARGO_ROUTER_PORT
   - service: http_status:404
EOF_CF
    else
      cat > "$ETC/cloudflared.yml" <<EOF_CF
 tunnel: $tid
 credentials-file: /root/.cloudflared/$tid.json
 ingress:
   - hostname: $SUB_DOMAIN
     service: http://127.0.0.1:$ARGO_ROUTER_PORT
   - hostname: $ARGO_DOMAIN
     service: http://127.0.0.1:$ARGO_ROUTER_PORT
   - service: http_status:404
EOF_CF
    fi
    sed -i 's/^ tunnel:/tunnel:/; s/^ credentials-file:/credentials-file:/; s/^ ingress:/ingress:/; s/^   -/  -/; s/^     service:/    service:/; s/^   - service:/  - service:/' "$ETC/cloudflared.yml"
    if [[ "$INIT" == systemd ]]; then
      cat > /etc/systemd/system/suoha-tunnel.service <<EOF_NAMED
[Unit]
Description=Suoha V2 Cloudflare Named Tunnel (subscription and Argo WS)
After=network-online.target suoha-sub.service suoha-argo-router.service
Requires=suoha-sub.service suoha-argo-router.service
[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config $ETC/cloudflared.yml run
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF_NAMED
      systemctl daemon-reload; systemctl enable --now suoha-tunnel
    else
      cat > /etc/init.d/suoha-tunnel <<EOF_NAMED_RC
#!/sbin/openrc-run
description="Suoha V2 Cloudflare Named Tunnel"
command="/usr/local/bin/cloudflared"
command_args="tunnel --config $ETC/cloudflared.yml run"
command_background="yes"
pidfile="/run/suoha-tunnel.pid"
output_log="$LOG_DIR/cloudflared.log"
error_log="$LOG_DIR/cloudflared.err"
EOF_NAMED_RC
      chmod +x /etc/init.d/suoha-tunnel; rc-update add suoha-tunnel default; rc-service suoha-tunnel restart
    fi
  fi
}


refresh_all(){
  require_root
  [[ -f "$ETC/settings.env" && -f "$CREDENTIALS" ]] || die "尚未安装 Suoha V2"
  # shellcheck disable=SC1090
  source "$ETC/settings.env"
  if [[ "$TUNNEL_MODE" == 2 ]]; then
    local quick_host=""
    for _ in $(seq 1 60); do
      quick_host="$(grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | tail -n1 | sed 's#https://##')"
      [[ -n "$quick_host" ]] && break
      sleep 1
    done
    [[ -n "$quick_host" ]] || die "尚未从 Quick Tunnel 日志获取到新域名；请检查 $LOG_DIR/cloudflared.log"
    if [[ "$quick_host" != "${ARGO_HOST:-}" ]]; then
      sed -i "s|^ARGO_HOST=.*|ARGO_HOST='$quick_host'|" "$ETC/settings.env"
      log "Quick Tunnel 域名已更新：$quick_host"
    fi
  fi
  write_subscription
  log "订阅与 Argo 节点列表已刷新"
}


upgrade_all(){
  require_root
  detect_platform
  local backup="/root/suoha-v2-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  chmod 700 "$backup"
  [[ -d "$ETC" ]] && cp -a "$ETC" "$backup/" || true
  [[ -d "$LOG_DIR" ]] && cp -a "$LOG_DIR" "$backup/" || true
  log "已备份旧版配置到：$backup"
  if [[ "$INIT" == systemd ]]; then
    for unit in suoha-v2 suoha-sub suoha-argo-router suoha-tunnel; do
      systemctl stop "$unit" 2>/dev/null || true
    done
  else
    for unit in suoha-tunnel suoha-argo-router suoha-sub suoha-v2; do
      rc-service "$unit" stop 2>/dev/null || true
    done
  fi
  log "旧版服务已停止，开始升级安装 V$VERSION"
  install_all
}

install_all(){
  require_root; detect_platform; install_dependencies; start_scheduler; create_service_user; install_cloudflared; install_singbox
  ask_config
  if [[ -f "$0" ]]; then install -m 0700 "$0" /usr/local/bin/suoha-v2
  elif [[ "$TUNNEL_MODE" == 2 ]]; then die "Quick Tunnel 自动刷新需要从本地脚本文件运行，请先下载脚本再执行"
  fi
  make_credentials; build_config; service_unit; sub_service
  if [[ "$TUNNEL_MODE" != 1 ]]; then argo_router_service; cloudflared_tunnel; fi
  write_subscription
  log "部署完成。sing-box 配置和凭证已写入 $ETC（权限 600）。"
  show_info
}

show_info(){
  [[ -f "$ETC/settings.env" ]] || { echo "尚未安装"; return; }
  # shellcheck disable=SC1090
  source "$ETC/settings.env"; source "$CREDENTIALS"
  echo
  echo "========== Suoha V2 部署信息 =========="
  echo "sing-box: $(sing-box version | head -n1)"
  echo "Proxy host: $NODE_HOST"
  echo "VLESS Reality Vision TCP: $P_REALITY"
  echo "VLESS Reality gRPC TCP: $P_REALITY_GRPC"
  echo "Snell TCP: $P_SNELL"
  [[ -n "$PUBLIC6" ]] && echo "Shadowsocks IPv6 TCP: $P_SS6"
  if [[ -n "$PROXY_DOMAIN" ]]; then echo "Hysteria2 UDP: $P_HY2"; echo "TUIC UDP: $P_TUIC"; echo "AnyTLS TCP: $P_ANYTLS"; echo "Trojan TCP: $P_TROJAN"; fi
  if [[ "$TUNNEL_MODE" == 1 && -n "$PROXY_DOMAIN" ]]; then
    echo "Base64 订阅：https://$PROXY_DOMAIN:$SUB_PORT/$SUB_TOKEN/sub.txt（需放行 TCP $SUB_PORT）"
    echo "Clash/Mihomo：https://$PROXY_DOMAIN:$SUB_PORT/$SUB_TOKEN/clash.yaml"
    echo "URI 列表：https://$PROXY_DOMAIN:$SUB_PORT/$SUB_TOKEN/nodes.txt"
    echo "Surge：https://$PROXY_DOMAIN:$SUB_PORT/$SUB_TOKEN/surge.conf"
  elif [[ "$TUNNEL_MODE" == 1 ]]; then
    echo "本地 Base64 订阅：http://127.0.0.1:$SUB_PORT/$SUB_TOKEN/sub.txt（仅本机）"
    echo "本地 Clash/Mihomo：http://127.0.0.1:$SUB_PORT/$SUB_TOKEN/clash.yaml"
  else
    echo "本地 Base64 订阅：http://127.0.0.1:$ARGO_ROUTER_PORT/$SUB_TOKEN/sub.txt"
    echo "本地 Clash/Mihomo：http://127.0.0.1:$ARGO_ROUTER_PORT/$SUB_TOKEN/clash.yaml"
  fi
  case "$TUNNEL_MODE" in
    1) echo "订阅入口：直连 HTTPS（未设置代理域名时仅本机可访问）；" ;;
    2) echo "Argo / 订阅域名：https://${ARGO_HOST:-待获取}"; echo "Base64 订阅：https://${ARGO_HOST:-待获取}/$SUB_TOKEN/sub.txt"; echo "Clash/Mihomo：https://${ARGO_HOST:-待获取}/$SUB_TOKEN/clash.yaml"; echo "URI 列表：https://${ARGO_HOST:-待获取}/$SUB_TOKEN/nodes.txt"; echo "Surge：https://${ARGO_HOST:-待获取}/$SUB_TOKEN/surge.conf" ;;
    3) echo "订阅公网地址：https://$SUB_DOMAIN/$SUB_TOKEN/sub.txt"; echo "Clash/Mihomo：https://$SUB_DOMAIN/$SUB_TOKEN/clash.yaml"; echo "URI 列表：https://$SUB_DOMAIN/$SUB_TOKEN/nodes.txt"; echo "Surge：https://$SUB_DOMAIN/$SUB_TOKEN/surge.conf"; echo "Argo 节点域名：$ARGO_DOMAIN" ;;
  esac
  echo "凭证文件：$CREDENTIALS（请妥善保管，不要公开）"
  echo "配置校验：sing-box check -c $SB_CONFIG"
  echo "======================================="
}

status_all(){
  require_root; detect_platform
  sing-box version 2>/dev/null || true
  if [[ "$INIT" == systemd ]]; then systemctl --no-pager --full status suoha-v2 suoha-sub suoha-argo-router suoha-tunnel 2>/dev/null || true; else rc-service suoha-v2 status 2>/dev/null || true; rc-service suoha-sub status 2>/dev/null || true; rc-service suoha-argo-router status 2>/dev/null || true; rc-service suoha-tunnel status 2>/dev/null || true; fi
  show_info
}

uninstall_all(){
  require_root; detect_platform
  echo "将卸载 Suoha V2 服务及程序配置。凭证和订阅会备份到 /root/suoha-v2-backup-时间戳。"
  read -r -p "确认卸载？输入 YES：" confirm
  [[ "$confirm" == YES ]] || { echo "已取消"; return; }
  local backup="/root/suoha-v2-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"; cp -a "$ETC" "$backup/" 2>/dev/null || true
  if [[ "$INIT" == systemd ]]; then
    for s in suoha-v2 suoha-sub suoha-argo-router suoha-tunnel; do systemctl disable --now "$s" 2>/dev/null || true; done
    rm -f /etc/systemd/system/suoha-v2.service /etc/systemd/system/suoha-sub.service /etc/systemd/system/suoha-argo-router.service /etc/systemd/system/suoha-tunnel.service
    systemctl daemon-reload
  else
    for s in suoha-v2 suoha-sub suoha-argo-router suoha-tunnel; do rc-service "$s" stop 2>/dev/null || true; rc-update del "$s" default 2>/dev/null || true; rm -f "/etc/init.d/$s"; done
    rm -f /etc/conf.d/suoha-sub
  fi
  rm -rf "$ETC" "$LOG_DIR"
  echo "卸载完成。备份位置：$backup。cloudflared 和 sing-box 二进制及系统依赖保留，避免误删其他服务共用组件。"
}

main(){
  local action="${1:-install}"
  case "$action" in
    install) install_all ;;
    upgrade) upgrade_all ;;
    status) status_all ;;
    refresh) refresh_all ;;
    uninstall) uninstall_all ;;
    *) echo "用法：$0 [install|upgrade|status|refresh|uninstall]"; exit 2 ;;
  esac
}
main "$@"
