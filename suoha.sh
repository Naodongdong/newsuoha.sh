#!/usr/bin/env bash
# Suoha V2 - multi-distro sing-box deployment manager
# Supported: Ubuntu, Debian, Alpine | init: systemd / OpenRC
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
APP="suoha-v2"
BASE="/opt/suoha-v2"
ETC="/etc/suoha-v2"
CERT_DIR="$ETC/cert"
LOG_DIR="/var/log/suoha-v2"
LOG_FILE="$LOG_DIR/install.log"
SB_CONFIG="$ETC/config.json"
CREDENTIALS="$ETC/credentials.env"
SUB_DIR="$ETC/subscription"
SUB_SERVER="$ETC/sub_server.py"
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
  if ! id suoha >/dev/null 2>&1; then
    if [[ "$PKG" == apk ]]; then adduser -S -D -H -s /sbin/nologin suoha; else useradd --system --no-create-home --shell /usr/sbin/nologin suoha; fi
