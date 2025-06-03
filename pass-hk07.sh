#!/bin/bash

# 检查运行权限
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户运行此脚本！"
    exit 1
fi

# 定义颜色
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

# 配置参数
API_TOKEN="ZCi8YCsNVEzJJt32-QB7QsQlY6A8dxwwqMKmM7dF"  # 替换为你的 Cloudflare API Token
DOMAIN="hk07.fxscloud.com"                            # 子域名
ROOT_DOMAIN="fxscloud.com"                            # 主域名
IP_FILE="/tmp/current_ip.txt"                         # 存储当前 IP 的文件路径
LOG_FILE="/var/log/cloudflare_ddns.log"               # 日志文件

# 日志记录函数
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# 检查 jq
if ! command -v jq &>/dev/null; then
    log "${Info} 检测到 jq 未安装，正在安装 jq..."
    if [ -f /etc/debian_version ]; then
        apt update && apt install -y jq
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release && yum install -y jq
    else
        log "${Error} 无法自动安装 jq，请手动安装后重试。"
        exit 1
    fi
fi

# 设置内核参数
log "${Info} 开始优化 Linux 内核参数..."
cat <<EOF > /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 500000
net.core.optmem_max = 81920
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_mem = 786432 1048576 1572864
net.mptcp.enabled = 1
EOF
sysctl -p
log "${Info} 内核参数优化完成！"

# 调整 ulimit
log "${Info} 调整文件描述符限制..."
cat <<EOF >> /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

log "${Info} 调整 systemd 资源限制..."
cat <<EOF >> /etc/systemd/system.conf
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

cat <<EOF >> /etc/systemd/user.conf
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

systemctl daemon-reexec
log "${Info} 优化完成，建议重启服务器以生效。"

# 设置时区
log "${Info} 设置系统时区为 Asia/Shanghai..."
echo "Asia/Shanghai" > /etc/timezone
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
dpkg-reconfigure -f noninteractive tzdata
log "${Info} 时区设置完成。"

# Cloudflare DDNS 更新逻辑
update_ddns() {
    CURRENT_IP=$(curl -s https://api.ipify.org)
    if [ -z "$CURRENT_IP" ]; then
        log "${Error} 无法获取公网 IP。"
        return 1
    fi

    if [ -f "$IP_FILE" ]; then
        LAST_IP=$(cat "$IP_FILE")
        if [ "$CURRENT_IP" == "$LAST_IP" ]; then
            log "${Info} IP 无变化，无需更新。"
            return 0
        fi
    fi

    log "${Info} 检测到公网 IP 变化：$CURRENT_IP"

    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
        log "${Error} 获取 Zone ID 失败。"
        return 1
    fi

    RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
        log "${Error} 获取 Record ID 失败。"
        return 1
    fi

    UPDATE_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")

    if echo "$UPDATE_RESPONSE" | grep -q "\"success\":true"; then
        log "${Info} DDNS 更新成功，$DOMAIN -> $CURRENT_IP"
        echo "$CURRENT_IP" > "$IP_FILE"
    else
        log "${Error} DDNS 更新失败。"
        return 1
    fi
}

# 下载并执行 install.sh（可选部分）
log "${Info} 下载 install.sh 脚本..."
wget -O install.sh --no-check-certificate http://ytpass.fxscloud.com:666/client/y47gIXFWsbHrMQRX/install.sh
if [ $? -eq 0 ]; then
    bash install.sh && rm -f install.sh
    log "${Info} install.sh 执行完成。"
else
    log "${Error} 下载 install.sh 失败！"
fi

# 设置定时任务（关键修复部分）
log "${Info} 正在设置 crontab 定时任务..."
SCRIPT_PATH="$(realpath "$0")"
crontab -l 2>/dev/null | grep -v "cloudflare_ddns.sh" > /tmp/crontab.tmp
echo "* * * * * /bin/bash $SCRIPT_PATH >> /var/log/cloudflare_ddns.log 2>&1" >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp && rm -f /tmp/crontab.tmp
log "${Info} Crontab 定时任务设置完成：每分钟执行 $SCRIPT_PATH"

# 手动执行一次
update_ddns

log "${Info} 所有步骤执行完成，建议重启系统以完全应用所有优化配置。"
