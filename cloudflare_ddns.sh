#!/bin/bash

# ========= 配置信息 =========
CF_API_TOKEN="ZCi8YCsNVEzJJt32-QB7QsQlY6A8dxwwqMKmM7dF"
CF_ZONE_ID="你的Zone ID"
CF_RECORD_ID="你的记录ID"
CF_DOMAIN_NAME="jp01.fxscloud.com"
# ============================

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [信息] $1"
}

err() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [错误] $1" >&2
}

get_ip() {
    curl -fsSL https://api64.ipify.org || curl -fsSL https://ipinfo.io/ip
}

update_ddns() {
    local current_ip=$(get_ip)
    [[ -z "$current_ip" ]] && err "获取公网 IP 失败" && return 1

    local record_ip=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" | grep -oE '"content":"[^"]+"' | cut -d'"' -f4)

    if [[ "$current_ip" == "$record_ip" ]]; then
        log "IP 未变化：$current_ip"
    else
        log "IP 变化：$record_ip → $current_ip，开始更新..."
        local result=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            
            --data "{\"type\":\"A\",\"name\":\"$CF_DOMAIN_NAME\",\"content\":\"$current_ip\",\"ttl\":120,\"proxied\":false}")

        if echo "$result" | grep -q "\"success\":true"; then
            log "更新成功：$current_ip"
        else
            err "更新失败，响应：$result"
        fi
    fi
}

# ========= 自动保存自身并重新执行（若通过管道运行） =========
if [[ "$0" == "/dev/fd/"* || "$0" == "/proc/"* ]]; then
    log "检测到脚本是通过管道方式运行，将保存为 /root/cloudflare_ddns.sh..."
    curl -fsSL https://raw.githubusercontent.com/dmdmdmxy/tcp/refs/heads/main/cloudflare_ddns.sh -o /root/cloudflare_ddns.sh
    chmod +x /root/cloudflare_ddns.sh
    /bin/bash /root/cloudflare_ddns.sh
    exit $?
fi

# ========= 设置 crontab =========
SCRIPT_PATH=$(realpath "$0")
(crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "* * * * * /bin/bash $SCRIPT_PATH >> /var/log/cloudflare_ddns.log 2>&1") | crontab -
log "定时任务已添加：每分钟执行 $SCRIPT_PATH"

# ========= 手动执行一次 =========
update_ddns
