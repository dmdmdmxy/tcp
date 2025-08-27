#!/bin/bash
set -euo pipefail

# ==============================
# Cloudflare DDNS + 系统优化脚本
# ==============================

# -------- 基础与安全 --------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本！"
  exit 1
fi

# 日志
LOG_FILE="/var/log/cloudflare_ddns.log"
mkdir -p "$(dirname "$LOG_FILE")"
Green="\033[32m"; Red="\033[31m"; NC="\033[0m"
Info="${Green}[信息]${NC}"; Error="${Red}[错误]${NC}"; Tip="${Green}[注意]${NC}"
log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }

# PATH（cron 环境精简，显式声明）
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# -------- 变量配置（按需修改） --------
# 从环境变量读取 Token（更安全）
API_TOKEN="${CF_API_TOKEN:-}"
if [ -z "$API_TOKEN" ]; then
  log "${Error} 未设置 CF_API_TOKEN 环境变量！"
  exit 1
fi

DOMAIN="pass.jp004.fxscloud.com"   # 要更新的完整子域名
ROOT_DOMAIN="fxscloud.com"         # 根域名
ENABLE_IPV6=true                   # 是否同时更新 AAAA 记录（true/false）
DEFAULT_PROXIED=false              # 默认是否开启橙云（若已存在记录，会沿用原值）
IPV4_FILE="/tmp/current_ip_v4.txt"
IPV6_FILE="/tmp/current_ip_v6.txt"

# -------- 依赖检查 --------
if ! command -v jq &>/dev/null; then
  log "${Info} 检测到 jq 未安装，正在安装 jq..."
  if [ -f /etc/debian_version ]; then
    apt-get update -y && apt-get install -y jq
  elif [ -f /etc/redhat-release ]; then
    yum install -y epel-release && yum install -y jq
  else
    log "${Error} 无法自动安装 jq，请手动安装后重试。"
    exit 1
  fi
fi

if ! command -v curl &>/dev/null; then
  log "${Info} 检测到 curl 未安装，正在安装 curl..."
  if [ -f /etc/debian_version ]; then
    apt-get update -y && apt-get install -y curl
  elif [ -f /etc/redhat-release ]; then
    yum install -y curl
  else
    log "${Error} 无法自动安装 curl，请手动安装后重试。"
    exit 1
  fi
fi

# -------- 系统优化（保持你原意并修正 heredoc） --------
log "${Info} 开始优化 Linux 内核参数..."
cat >/etc/sysctl.conf <<'EOF'
fs.file-max = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 256
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_mem = 2097152 2621440 3145728
net.ipv4.tcp_rmem = 8192 262144 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# 如需启用 MPTCP：
# net.mptcp.enabled = 1
EOF

# limits
cat >/etc/security/limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
EOF

# systemd 资源限制
grep -q '^DefaultLimitNOFILE=' /etc/systemd/system.conf 2>/dev/null || echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
grep -q '^DefaultLimitNPROC=' /etc/systemd/system.conf 2>/dev/null || echo "DefaultLimitNPROC=1048576" >> /etc/systemd/system.conf
grep -q '^DefaultLimitNOFILE=' /etc/systemd/user.conf 2>/dev/null || echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/user.conf
grep -q '^DefaultLimitNPROC=' /etc/systemd/user.conf 2>/dev/null || echo "DefaultLimitNPROC=1048576" >> /etc/systemd/user.conf

sysctl -p || true
systemctl daemon-reexec || true
log "${Info} 内核参数与 systemd 限制已应用。"

# -------- 系统时区 --------
log "${Info} 配置系统时区为 Asia/Shanghai..."
echo "Asia/Shanghai" > /etc/timezone
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
if command -v dpkg-reconfigure &>/dev/null; then
  dpkg-reconfigure -f noninteractive tzdata || true
fi
log "${Info} 时区配置完成。"

# -------- Cloudflare DDNS 实现 --------
CF_API="https://api.cloudflare.com/client/v4"
CF_HEADERS=(-H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json")
ZONE_ID=""   # 允许自动发现；也可手动预置提高稳定性

get_ipv4() { curl -4 -fsS https://api.ipify.org || true; }
get_ipv6() { curl -6 -fsS https://api64.ipify.org || curl -6 -fsS https://api6.ipify.org || true; }

ensure_zone_id() {
  if [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "null" ]; then
    return 0
  fi
  local resp
  resp=$(curl -s -X GET "$CF_API/zones?name=$ROOT_DOMAIN&status=active" "${CF_HEADERS[@]}")
  ZONE_ID=$(echo "$resp" | jq -r '.result[0].id')
  if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
    log "${Error} 获取 Zone ID 失败：请检查 ROOT_DOMAIN 与 API Token 权限（需 Zone:Read）。"
    return 1
  fi
  return 0
}

# 统一的 upsert（A/AAAA）
upsert_dns_record() {
  local record_name="$1"
  local record_type="$2"   # A 或 AAAA
  local ip="$3"
  local ip_file="$4"

  local resp record_id record_ttl record_proxied record_content
  resp=$(curl -s -X GET "$CF_API/zones/$ZONE_ID/dns_records?type=$record_type&name=$record_name" "${CF_HEADERS[@]}")
  record_id=$(echo "$resp" | jq -r '.result[0].id')

  if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
    record_ttl=$(echo "$resp"     | jq -r '.result[0].ttl')
    record_proxied=$(echo "$resp" | jq -r '.result[0].proxied')
    record_content=$(echo "$resp" | jq -r '.result[0].content')

    [ "$record_ttl" = "null" ] && record_ttl=1
    if [ "$record_proxied" = "null" ]; then
      record_proxied="$DEFAULT_PROXIED"
    fi

    if [ "$record_content" = "$ip" ]; then
      log "${Info} $record_type 记录 $record_name 已是 $ip，无需更新。"
      echo "$ip" > "$ip_file"
      return 0
    fi

    local payload
    payload=$(jq -nc \
      --arg type "$record_type" \
      --arg name "$record_name" \
      --arg content "$ip" \
      --argjson ttl "$record_ttl" \
      --argjson proxied "$record_proxied" \
      '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')

    local upd
    upd=$(curl -s -X PUT "$CF_API/zones/$ZONE_ID/dns_records/$record_id" "${CF_HEADERS[@]}" --data "$payload")
    if echo "$upd" | jq -e '.success == true' >/dev/null; then
      log "${Info} 已更新 $record_type：$record_name -> $ip"
      echo "$ip" > "$ip_file"
      return 0
    else
      log "${Error} 更新失败：$(echo "$upd" | jq -c '.errors')"
      return 1
    fi
  else
    local payload
    payload=$(jq -nc \
      --arg type "$record_type" \
      --arg name "$record_name" \
      --arg content "$ip" \
      --argjson ttl 1 \
      --argjson proxied "$DEFAULT_PROXIED" \
      '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')

    local crt
    crt=$(curl -s -X POST "$CF_API/zones/$ZONE_ID/dns_records" "${CF_HEADERS[@]}" --data "$payload")
    if echo "$crt" | jq -e '.success == true' >/dev/null; then
      log "${Info} 已创建 $record_type：$record_name -> $ip"
      echo "$ip" > "$ip_file"
      return 0
    else
      log "${Error} 创建失败：$(echo "$crt" | jq -c '.errors')"
      return 1
    fi
  fi
}

update_ddns() {
  ensure_zone_id || return 1

  # IPv4
  local v4
  v4=$(get_ipv4)
  if [ -n "$v4" ]; then
    if [ -f "$IPV4_FILE" ] && [ "$(cat "$IPV4_FILE")" = "$v4" ]; then
      log "${Info} IPv4 未变化（$v4），跳过。"
    else
      upsert_dns_record "$DOMAIN" "A" "$v4" "$IPV4_FILE" || log "${Error} IPv4 更新失败。"
    fi
  else
    log "${Error} 获取 IPv4 失败，请检查网络或出口。"
  fi

  # IPv6（可选）
  if [ "$ENABLE_IPV6" = true ]; then
    local v6
    v6=$(get_ipv6 || true)
    if [ -n "$v6" ]; then
      if [ -f "$IPV6_FILE" ] && [ "$(cat "$IPV6_FILE")" = "$v6" ]; then
        log "${Info} IPv6 未变化（$v6），跳过。"
      else
        upsert_dns_record "$DOMAIN" "AAAA" "$v6" "$IPV6_FILE" || log "${Error} IPv6 更新失败。"
      fi
    else
      log "${Tip} 未获取到 IPv6（可能无 v6 出口或网络不通），跳过 AAAA。"
    fi
  fi
}

# -------- 业务：下载并执行 install.sh（保留你的逻辑） --------
log "${Info} 开始下载并执行 install.sh 脚本..."
TMP_INSTALL="/tmp/install.sh"
if curl -fsSLo "$TMP_INSTALL" "http://ytpass.fxscloud.com:666/client/4xtnq6UZ3Lcei0VK/install.sh"; then
  bash "$TMP_INSTALL" && rm -f "$TMP_INSTALL"
  log "${Info} install.sh 脚本执行完成！"
else
  log "${Error} 下载 install.sh 脚本失败！"
  # 不终止整体，以便后续 DDNS 仍可工作
fi

# -------- cron：每分钟自我执行（去重） --------
# 取本脚本真实路径（适配软链）
SCRIPT_PATH="$(readlink -f "$0")"
CRON_LINE="* * * * * /bin/bash $SCRIPT_PATH >> $LOG_FILE 2>&1"
# 去重
( crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" ; echo "$CRON_LINE" ) | crontab -
log "${Info} 定时任务已创建：每分钟执行一次。"

# -------- 立即执行一次 DDNS --------
update_ddns

log "${Info} 所有步骤已完成。"
