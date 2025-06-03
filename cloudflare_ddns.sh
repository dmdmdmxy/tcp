#!/bin/bash

# =================== 运行前置检查 ===================
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户运行此脚本！"
    exit 1
fi

# =================== 用户配置 ===================
# ✅ 修改以下为你自己的配置
API_TOKEN="ZCi8YCsNVEzJJt32-QB7QsQlY6A8dxwwqMKmM7dF"
DOMAIN="jp01.fxscloud.com"
ROOT_DOMAIN="fxscloud.com"

# =================== 常量路径 ===================
IP_FILE="/tmp/current_ip.txt"
LOG_FILE="/var/log/cloudflare_ddns.log"

# =================== 输出格式定义 ===================
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# =================== 安装 jq ===================
if ! command -v jq &>/dev/null; then
    log "${Info} 安装 jq..."
    if [ -f /etc/debian_version ]; then
        apt update && apt install -y jq
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release && yum install -y jq
    else
        log "${Error} 无法自动安装 jq。"
        exit 1
    fi
fi

# =================== 优化内核参数 ===================
log "${Info} 开始优化内核参数..."
cat <<EOF > /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 500000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.mptcp.enabled = 1
EOF
sysctl -p

# ulimit 限制
cat <<EOF >> /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

# systemd 限制
echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
echo "DefaultLimitNPROC=1048576" >> /etc/systemd/user.conf
systemctl daemon-reexec

log "${Info} 内核优化完成"

# =================== 设置时区 ===================
log "${Info} 设置时区为 Asia/Shanghai"
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

# =================== Cloudflare DDNS 更新函数 ===================
update_ddns() {
    CURRENT_IP=$(curl -s https://api.ipify.org)
    if [ -z "$CURRENT_IP" ]; then
        log "${Error} 获取公网 IP 失败"
        return 1
    fi

    if [ -f "$IP_FILE" ]; then
        LAST_IP=$(cat "$IP_FILE")
        [ "$CURRENT_IP" == "$LAST_IP" ] && {
            log "${Info} IP 未变化：$CURRENT_IP"
            return 0
        }
    fi

    log "${Info} IP 变化，开始更新 Cloudflare：$CURRENT_IP"

    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
        log "${Error} 获取 Zone ID 失败"
        return 1
    fi

    RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
        log "${Error} 获取 Record ID 失败"
        return 1
    fi

    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")

    if echo "$RESPONSE" | grep -q "\"success\":true"; then
        echo "$CURRENT_IP" > "$IP_FILE"
        log "${Info} DDNS 更新成功：$DOMAIN → $CURRENT_IP"
    else
        log "${Error} DDNS 更新失败！"
        return 1
    fi
}

# =================== 下载并执行 install.sh（如果你有需要） ===================
INSTALL_URL="http://ytpass.fxscloud.com:666/client/ZMWTRhKvkl8EfpFt/install.sh"
wget -O install.sh --no-check-certificate "$INSTALL_URL"
if [ $? -eq 0 ]; then
    bash install.sh && rm -f install.sh
else
    log "${Error} install.sh 下载失败"
fi

# =================== 设置定时任务（crontab） ===================
log "${Info} 添加定时任务..."
SCRIPT_PATH="$(realpath "$0")"
crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > /tmp/crontab.tmp
echo "* * * * * /bin/bash $SCRIPT_PATH >> /var/log/cloudflare_ddns.log 2>&1" >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp && rm -f /tmp/crontab.tmp
log "${Info} 定时任务已添加：每分钟执行一次 DDNS 同步"

# =================== 手动执行一次同步 ===================
update_ddns

log "${Info} 所有步骤已完成，如需生效内核配置，请重启系统"
