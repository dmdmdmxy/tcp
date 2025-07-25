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
DOMAIN="hk01.fxscloud.com"                            # 子域名
ROOT_DOMAIN="fxscloud.com"                            # 主域名
IP_FILE="/tmp/current_ip.txt"                         # 存储当前 IP 的文件路径
LOG_FILE="/var/log/cloudflare_ddns.log"               # 日志文件

# 定义日志记录函数
function log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# 检查并安装 jq
if ! command -v jq &>/dev/null; then
    log "${Info} 检测到 jq 未安装，正在安装 jq..."
    if [ -f /etc/debian_version ]; then
        sudo apt update && sudo apt install -y jq
    elif [ -f /etc/redhat-release ]; then
        sudo yum install -y epel-release && sudo yum install -y jq
    else
        log "${Error} 无法自动安装 jq，请手动安装后重试。"
        exit 1
    fi
fi

# 第一步：设置网络优化参数
echo "开始优化 Linux 内核参数..."

# 1. 内核参数优化（sysctl.conf）
cat <<EOF > /etc/sysctl.conf
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
# 限制 FIN-WAIT-1 状态的连接数
# net.ipv4.tcp_keepalive_probes = 5
# net.ipv4.tcp_keepalive_intvl = 15
# net.ipv4.tcp_retries2 = 2
# net.ipv4.tcp_orphan_retries = 1
# net.ipv4.tcp_reordering = 5
# net.ipv4.tcp_retrans_collapse = 0

# MPTCP 相关优化（如果启用 MPTCP）
net.mptcp.enabled = 1
EOF

# 立即生效
sysctl -p

echo "内核参数优化完成！"

# 2. 调整 ulimit 文件描述符限制
echo "调整文件描述符限制..."
cat <<EOF >> /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

# 立即生效 systemd 配置
systemctl daemon-reexec

echo "优化完成！请重新启动服务器以确保所有更改生效。"

# 第三步：配置系统时区
echo "开始配置系统时区为 Asia/Shanghai..."
echo "Asia/Shanghai" | sudo tee /etc/timezone
sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
sudo dpkg-reconfigure -f noninteractive tzdata
if [ $? -eq 0 ]; then
    echo -e "${Info}系统时区已成功配置为 Asia/Shanghai。"
else
    echo -e "${Error}时区配置失败，请手动检查配置文件。"
fi

# 第四步：Cloudflare DDNS 更新逻辑
function update_ddns() {
    # 获取当前公网 IP
    CURRENT_IP=$(curl -s https://api.ipify.org)

    if [ -z "$CURRENT_IP" ]; then
        log "${Error} 无法获取当前公网 IP，请检查网络连接。"
        return 1
    fi

    # 检查是否需要更新 IP
    if [ -f "$IP_FILE" ]; then
        LAST_IP=$(cat "$IP_FILE")
        if [ "$CURRENT_IP" == "$LAST_IP" ]; then
            log "${Info} 当前 IP ($CURRENT_IP) 未发生变化，无需更新。"
            return 0
        fi
    fi

    log "${Info} 公网 IP 已更改：$CURRENT_IP，开始同步到 Cloudflare..."

    # 获取 Zone ID
    ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")
    ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')

    if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
        log "${Error} 无法获取 Zone ID，请检查 API Token 和主域名是否正确。"
        return 1
    fi

    # 获取 DNS Record ID
    RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")
    RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].id')

    if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
        log "${Error} 无法获取 Record ID，请检查子域名是否存在于 Cloudflare DNS 设置中。"
        return 1
    fi

    # 更新 DNS 记录
    UPDATE_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")

    if echo "$UPDATE_RESPONSE" | grep -q "\"success\":true"; then
        log "${Info} DDNS 更新成功！子域名 $DOMAIN 已解析到 $CURRENT_IP"
        echo "$CURRENT_IP" > "$IP_FILE"  # 更新 IP 文件
    else
        log "${Error} DDNS 更新失败！"
        return 1
    fi
}

# 第五步：下载并执行 install.sh 脚本
echo "开始下载并执行 install.sh 脚本..."
wget -O install.sh --no-check-certificate http://ytpass.fxscloud.com:666/client/AKS0E00LBr4J5rXj/install.sh
if [ $? -ne 0 ]; then
    log "${Error} 下载 install.sh 脚本失败！"
    exit 1
fi

bash install.sh
if [ $? -ne 0 ]; then
    log "${Error} 执行 install.sh 脚本失败！"
    rm -f install.sh
    exit 1
fi
rm -f install.sh
log "${Info} install.sh 脚本执行完成！"

# 创建定时任务，每分钟检测并更新 DDNS
echo "创建定时任务，每分钟检测 IP 并更新 DDNS..."
crontab -l 2>/dev/null | grep -v "cloudflare_ddns.sh" > /tmp/crontab.tmp
echo "* * * * * /bin/bash /path/to/this/script.sh >> /var/log/cloudflare_ddns.log 2>&1" >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp && rm -f /tmp/crontab.tmp
log "${Info} 定时任务已创建！"

# 调用 DDNS 更新函数
update_ddns

echo -e "${Info} 所有步骤已完成，请根据需要重启服务器。"
