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
DOMAIN="2.aaa-jp02.yunti.best"                            # 子域名
ROOT_DOMAIN="yunti.best"                           # 主域名

# 第一步：设置网络优化参数
echo "正在配置网络优化参数..."

cat <<EOF >> /etc/sysctl.conf
# 网络优化参数
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.all.rp_filter = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096
net.ipv4.tcp_abort_on_overflow = 1
vm.swappiness = 10
fs.file-max = 6553560
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

# 第五步：运行多个 Docker 容器
echo "开始运行多个 Docker 容器..."

# 运行第一个容器
docker run --restart=on-failure --name gw-projp-64-12-32-4-11-33-21 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e soga_key=Ox2YKGI6WiUBNXr1ZD2Ev0Y3HrLbev9v \
-e type=sspanel-uim \
-e server_type=v2ray \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu/ \
-e webapi_key=qwer123 \
-e node_id=64,12,32,4,11,33,21 \
-e user_speed_limit=100 \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=150 \
-e dy_limit_speed=80 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
-e dy_limit_white_user_id=3 \
vaxilu/soga


# 运行第二个容器
docker run --restart=on-failure --name p.ssrjp-02-04-06 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=ssr \
-e soga_key=XqnhglMPQZKvkEOTVWcZKAWCPNyFhqJi \
-e api=webapi \
-e webapi_url=https://v2ray.yuntivpn.xyz \
-e webapi_key=NimaQu \
-e node_id=365,366,367 \
-e proxy_protocol=true \
-e redis_enable=true \
-e redis_addr=195.123.241.153:12345 \
-e redis_password=fgsdfgasgdfui \
-e redis_db=5 \
-e conn_limit_expiry=5 \
-e dy_limit_enable=true \
-e dy_limit_duration=20:00-24:00,00:00-02:00 \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=200 \
-e dy_limit_speed=80 \
-e dy_limit_time=600 \
vaxilu/soga

# 运行第三个容器
docker run --restart=on-failure --name b.jp-01-02-03-04 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=v2ray \
-e soga_key=tLlTYQC9W0j1Ihnq5d7jYI82kQbxjfYG \
-e api=webapi \
-e webapi_url=https://v2ray.yuntivpn.xyz \
-e webapi_key=NimaQu \
-e node_id=232,233,260,261 \
-e proxy_protocol=true \
-e redis_enable=true \
-e redis_addr=195.123.241.153:12345 \
-e redis_password=fgsdfgasgdfui \
-e redis_db=6 \
-e conn_limit_expiry=5 \
-e dy_limit_enable=true \
-e dy_limit_duration=20:00-24:00,00:00-02:00 \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=200 \
-e dy_limit_speed=80 \
-e dy_limit_time=600 \
vaxilu/soga

# 运行第四个容器
docker run --restart=on-failure --name p.jp-01-03-05 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=v2ray \
-e soga_key=tLlTYQC9W0j1Ihnq5d7jYI82kQbxjfYG \
-e api=webapi \
-e webapi_url=https://v2ray.yuntivpn.xyz \
-e webapi_key=NimaQu \
-e node_id=389,390,391 \
-e proxy_protocol=true \
-e redis_enable=true \
-e redis_addr=195.123.241.153:12345 \
-e redis_password=fgsdfgasgdfui \
-e redis_db=5 \
-e conn_limit_expiry=5 \
-e dy_limit_enable=true \
-e dy_limit_duration=20:00-24:00,00:00-02:00 \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=200 \
-e dy_limit_speed=80 \
-e dy_limit_time=600 \
vaxilu/soga



echo -e "${Info}所有 Docker 容器已成功启动！"

echo -e "${Info}所有步骤已完成！"
