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
DOMAIN="hk13.fxscloud.com"                            # 子域名
ROOT_DOMAIN="fxscloud.com"                            # 主域名
IP_FILE="/tmp/current_ip.txt"                         # 存储当前 IP 的文件路径
LOG_FILE="/var/log/cloudflare_ddns.log"               # 日志文件

# 定义日志记录函数
function log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# 第一步：设置网络优化参数
echo "开始优化 Linux 内核参数..."

cat <<EOF > /etc/sysctl.conf
# 启用 BBR 拥塞控制算法
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 增大 TCP 连接数限制
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 500000
net.core.optmem_max = 81920

# TCP 读写缓冲区优化
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216

# 允许更多 TCP 连接
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1

# 启用 TCP Fast Open（TFO）
net.ipv4.tcp_fastopen = 3

# 增强 SYN Flood 保护
net.ipv4.tcp_syncookies = 1

# 允许更大的 socket buffer
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 降低 TCP 内存压力
net.ipv4.tcp_mem = 786432 1048576 1572864

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

# 3. 调整 systemd 资源限制
echo "调整 systemd 资源限制..."
cat <<EOF >> /etc/systemd/system.conf
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

cat <<EOF >> /etc/systemd/user.conf
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
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
wget -O install.sh --no-check-certificate http://ytpass.fxscloud.com:666/client/aoxQn6UTrVAatLvj/install.sh
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
