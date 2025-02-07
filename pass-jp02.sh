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
DOMAIN="jp02.fxscloud.com"                            # 子域名
ROOT_DOMAIN="fxscloud.com"                           # 主域名

# 第一步：设置网络优化参数
echo "正在配置网络优化参数..."

cat <<EOF >> /etc/sysctl.conf
# 网络优化参数
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.lo.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.netfilter.nf_conntrack_buckets=67108864
net.netfilter.nf_conntrack_max=536870912
net.netfilter.nf_conntrack_tcp_timeout_established=600
net.netfilter.nf_conntrack_tcp_timeout_close_wait=10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_tcp_timeout_time_wait=60
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=60
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=60
net.netfilter.nf_conntrack_tcp_timeout_last_ack=30
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=30
net.netfilter.nf_conntrack_udp_timeout=5
net.netfilter.nf_conntrack_udp_timeout_stream=5
net.netfilter.nf_conntrack_generic_timeout=60

net.ipv4.tcp_syncookies=1
net.ipv4.tcp_retries1=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_orphan_retries=1
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_max_tw_buckets=65536
net.ipv4.tcp_max_syn_backlog=65536
net.core.netdev_max_backlog=65536
net.core.somaxconn=65536
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=60

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_autocorking=0
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_thin_linear_timeouts=1
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 16384 67108864
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=16384
net.core.wmem_default=16384
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mem=786432 1048576 26777216
net.ipv4.udp_mem=65536 131072 262144
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_pacing_ss_ratio=1000
net.ipv4.tcp_pacing_ca_ratio=200

net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_shrink_window=1
net.ipv4.tcp_rfc1337=1

EOF

sysctl -p
echo -e "${Info}网络优化参数已成功配置并应用！"

# 第二步：安装 Docker
echo "开始检查并安装 Docker..."
if docker version > /dev/null 2>&1; then
    echo -e "${Info}Docker 已安装，跳过安装步骤。"
else
    echo "Docker 未安装，开始安装..."
    curl -fsSL https://get.docker.com | bash
    if [ $? -ne 0 ]; then
        echo -e "${Error}Docker 安装失败，请检查网络或权限。"
        exit 1
    fi
fi

echo "重启 Docker 服务..."
service docker restart
if [ $? -ne 0 ]; then
    echo -e "${Error}Docker 服务重启失败，请手动检查服务状态。"
else
    echo -e "${Info}Docker 安装完成且服务已重启。"
fi

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

# 第四步：安装并配置 Cloudflare DDNS
echo "开始检查并安装 jq..."

if ! command -v jq &>/dev/null; then
    echo "检测到 jq 未安装，正在安装 jq..."
    if [ -f /etc/debian_version ]; then
        sudo apt update && sudo apt install -y jq
    elif [ -f /etc/redhat-release ]; then
        sudo yum install -y epel-release && sudo yum install -y jq
    else
        echo "无法自动安装 jq，请手动安装后重试。"
        exit 1
    fi
fi

echo "获取 Zone ID..."
ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json")
ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
    echo "无法获取 Zone ID，请检查 API Token 和主域名是否正确。"
    exit 1
fi
echo "Zone ID: $ZONE_ID"

echo "获取 Record ID..."
RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json")
RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].id')

if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
    echo "无法获取 Record ID，请检查子域名是否存在于 Cloudflare DNS 设置中。"
    exit 1
fi
echo "Record ID: $RECORD_ID"

CURRENT_IP=$(curl -s https://api.ipify.org)
if [ -z "$CURRENT_IP" ]; then
    echo "无法获取当前 IP 地址，请检查网络连接。"
    exit 1
fi

echo "正在更新 Cloudflare DNS 记录..."
UPDATE_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}")

if echo "$UPDATE_RESPONSE" | grep -q "\"success\":true"; then
    echo "DDNS 更新成功！子域名 $DOMAIN 已解析到 $CURRENT_IP"
else
    echo "DDNS 更新失败！"
    exit 1
fi


# 第五步：下载并执行 install.sh 脚本
echo "开始下载并执行 install.sh 脚本..."

wget -O install.sh --no-check-certificate http://ytpass.fxscloud.com:666/client/J6XHnj7FaJT6lzA2/install.sh
if [ $? -ne 0 ]; then
    echo -e "${Error}下载 DDNS 更新脚本失败！"
    exit 1
fi

bash install.sh
if [ $? -ne 0 ]; then
    echo -e "${Error}执行 DDNS 更新脚本失败！"
    rm -f install.sh
    exit 1
fi

rm install.sh -f
echo -e "${Info}install.sh 脚本执行完成！"

echo -e "${Info}所有步骤已完成！"
