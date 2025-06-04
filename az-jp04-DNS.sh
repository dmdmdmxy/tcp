#!/usr/bin/env bash
#
# ddns_update.sh
# 用途：检测 EC2 当前公网 IP，一旦变化，就同步到 Cloudflare DDNS。
# 建议路径：/usr/local/bin/ddns_update.sh
# 使用方法：chmod +x /usr/local/bin/ddns_update.sh
# Crontab 示例：*/1 * * * * root /usr/local/bin/ddns_update.sh

set -euo pipefail

#############################
# ======= 配置区域 =======
#############################

# Cloudflare 相关凭据（务必替换为你自己的）
CF_API_TOKEN="ZCi8YCsNVEzJJt32-QB7QsQlY6A8dxwwqMKmM7dF"
CF_ROOT_DOMAIN="fxscloud.com"      # 你的主域名
CF_SUBDOMAIN="azjp04.fxscloud.com"   # 要更新的子域名（全称）

# 本地缓存文件路径（保存上一次成功更新的 IP）
IP_CACHE_FILE="/var/run/ddns_ec2_current_ip.txt"

# 日志文件（所有输出同时写到屏幕和日志）
LOG_FILE="/var/log/cloudflare_ddns.log"

# 临时文件（获取新 IP）
TMP_IP_FILE="/tmp/ddns_ec2_new_ip.txt"

#############################
# ======== 函数区 =========
#############################

# 日志函数：把时间戳 + 内容 写到日志并输出到 stdout
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# 检查并安装 jq（如果 jq 不存在）
ensure_jq() {
    if ! command -v jq &>/dev/null; then
        log "【信息】检测到 jq 未安装，尝试自动安装..."
        if [[ -f /etc/debian_version ]]; then
            apt-get update -y && apt-get install -y jq
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y epel-release && yum install -y jq
        else
            log "【错误】无法自动安装 jq，请手动安装后重试。"
            exit 1
        fi
        log "【信息】jq 安装完成。"
    fi
}

# 获取当前公网 IP
fetch_current_ip() {
    # 推荐使用 ipify API，也可以换成 ifconfig.co、checkip.amazonaws.com 等
    curl -fsSL https://api.ipify.org > "${TMP_IP_FILE}" || {
        log "【错误】无法通过 api.ipify.org 获取公网 IP，检查网络连接或更换接口。"
        return 1
    }

    # 去除换行符
    tr -d '\r\n' < "${TMP_IP_FILE}"
}

# 获取 Cloudflare Zone ID（根据主域名）
get_zone_id() {
    local root="$1"
    local resp zone_id

    resp=$(curl -fsSL -X GET "https://api.cloudflare.com/client/v4/zones?name=${root}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    zone_id=$(echo "${resp}" | jq -r '.result[0].id // empty')
    if [[ -z "${zone_id}" ]]; then
        log "【错误】无法获取 Zone ID，请检查 CF_ROOT_DOMAIN 是否正确，以及 API_TOKEN 是否有读权限。"
        return 1
    fi
    echo "${zone_id}"
}

# 获取 Cloudflare DNS Record ID（根据 zone_id 和子域名）
get_record_id() {
    local zone_id="$1"
    local full_name="$2"
    local resp record_id

    resp=$(curl -fsSL -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${full_name}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    record_id=$(echo "${resp}" | jq -r '.result[0].id // empty')
    if [[ -z "${record_id}" ]]; then
        log "【错误】无法获取 Record ID，请检查子域名 ${full_name} 是否已经在 Cloudflare DNS 中存在。"
        return 1
    fi
    echo "${record_id}"
}

# 更新 Cloudflare DNS 记录（A 记录）
update_dns_record() {
    local zone_id="$1"
    local record_id="$2"
    local full_name="$3"
    local new_ip="$4"
    local resp

    # Cloudflare API 要求：PUT /zones/:zone_identifier/dns_records/:identifier
    resp=$(curl -fsSL -X PUT \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${full_name}\",\"content\":\"${new_ip}\",\"ttl\":120,\"proxied\":false}")

    if echo "${resp}" | grep -q '"success":true'; then
        log "【成功】Cloudflare DDNS 更新成功：${full_name} → ${new_ip}"
        return 0
    else
        log "【错误】Cloudflare DDNS 更新失败，接口返回："
        echo "${resp}" | tee -a "${LOG_FILE}"
        return 1
    fi
}

#############################
# ========= 主逻辑 =========
#############################

# 1. 确保 jq 存在
ensure_jq

# 2. 获取当前公网 IP
CURRENT_IP=$(fetch_current_ip) || exit 1
if [[ -z "${CURRENT_IP}" ]]; then
    log "【错误】获取的 CURRENT_IP 为空，退出。"
    exit 1
fi

# 3. 比对上次缓存的 IP
if [[ -f "${IP_CACHE_FILE}" ]]; then
    LAST_IP=$(< "${IP_CACHE_FILE}")
else
    LAST_IP=""
fi

if [[ "${CURRENT_IP}" == "${LAST_IP}" ]]; then
    # IP 未变化，什么都不做
    log "【信息】公网 IP 未变化，当前 IP：${CURRENT_IP}"
    exit 0
fi

# 4. IP 变化，开始更新 DDNS
log "【信息】检测到公网 IP 变化：上次=${LAST_IP:-“(无缓存)”}，当前=${CURRENT_IP} → 准备同步到 Cloudflare..."

ZONE_ID=$(get_zone_id "${CF_ROOT_DOMAIN}") || exit 1
RECORD_ID=$(get_record_id "${ZONE_ID}" "${CF_SUBDOMAIN}") || exit 1

if update_dns_record "${ZONE_ID}" "${RECORD_ID}" "${CF_SUBDOMAIN}" "${CURRENT_IP}"; then
    # 5. 更新本地缓存文件
    echo "${CURRENT_IP}" > "${IP_CACHE_FILE}"
    exit 0
else
    exit 1
fi
