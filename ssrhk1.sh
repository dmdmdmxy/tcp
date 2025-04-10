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
DOMAIN="awshk01.yunti.best"                            # 子域名
ROOT_DOMAIN="yunti.best"                           # 主域名

# 第一步：设置网络优化参数
echo "开始优化 Linux 内核参数..."

# 1. 内核参数优化（sysctl.conf）
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
docker run --restart=on-failure --name gw-ssr-basichk01 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=ssr \
-e soga_key=JGD4m9BkddmjLqL6AZVqEhvNkf0yGTEs \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu \
-e webapi_key=qwer123 \
-e forbidden_bit_torrent=true \
-e user_tcp_limit=800 \
-e node_id=117 \
-e proxy_protocol=true \
-e user_speed_limit=100 \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=100 \
-e dy_limit_speed=50 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
vaxilu/soga

echo -e "${Info}所有 Docker 容器已成功启动！"

# 第六步：安装并启动 Nezha 监控 Agent
echo "检查并安装 unzip..."
if ! command -v unzip &>/dev/null; then
    echo "unzip 未安装，正在安装..."
    apt update && apt install -y unzip
fi
echo "开始安装并启动 Nezha 监控 Agent..."

wget https://github.com/nezhahq/agent/releases/download/v0.20.5/nezha-agent_linux_amd64.zip && \
unzip nezha-agent_linux_amd64.zip && \
chmod +x nezha-agent && \
./nezha-agent service install -s 15.235.144.68:5555 -p txLL6yXl09qBwb1wyh

echo -e "${Info}Nezha 监控 Agent 安装并启动完成！"

# 第七步：创建并写入配置文件
echo "开始创建并写入配置文件..."

# 确保 /etc/soga 目录存在
if [ ! -d "/etc/soga" ]; then
    mkdir -p /etc/soga
    echo "已创建目录 /etc/soga"
else
    echo "目录 /etc/soga 已存在，跳过创建。"
fi

# 创建 /etc/soga/dns.yml 文件并写入内容
cat <<EOF > /etc/soga/dns.yml
hk-nf-disney.ytjscloud.com:62580:
  strategy: ipv4_first
  rules:
    - geosite:netflix
    - geosite:disney

gpt-jp01.ytjscloud.com:62580:
  strategy: ipv4_first
  rules:
    - domain:openai.com
    - domain:chat.openai.com
    - domain:challenges.cloudflare.com
    - domain:auth0.openai.com
    - domain:platform.openai.com
    - domain:ai.com
    - domain:chatgpt.com
    - domain:oaiusercontent.com
    - domain:browser-intake-datadoghq.com
    - domain:otokyo1a.turn.livekit.cloud
    - domain:media.giphy.com
    - domain:i1.wp.com
    - domain:s.gravatar.com
    - domain:api.revenuecat.com
    - domain:auth0.com
    - domain:o33249.ingest.sentry.io
    - domain:oaistatic.com
    - domain:featureassets.org
    - domain:prodregistryv2.org
EOF

if [ $? -eq 0 ]; then
    echo "文件 /etc/soga/dns.yml 已成功创建并写入内容。"
else
    echo "创建 /etc/soga/dns.yml 失败！"
    exit 1
fi

# 创建 /etc/soga/blockList 文件并写入内容
cat <<EOF > /etc/soga/blockList
port:7080,7081
EOF

if [ $? -eq 0 ]; then
    echo "文件 /etc/soga/blockList 已成功创建并写入内容。"
else
    echo "创建 /etc/soga/blockList 失败！"
    exit 1
fi
# 第八步：重新启动所有 Docker 容器
echo "开始重新启动所有 Docker 容器..."

# 停止所有容器
docker stop $(docker ps -a | awk '{ print $1}' | tail -n +2)
if [ $? -eq 0 ]; then
    echo -e "${Info}所有 Docker 容器已成功停止。"
else
    echo -e "${Error}停止 Docker 容器时发生错误，请检查。"
    exit 1
fi

# 启动所有容器
docker start $(docker ps -a | awk '{ print $1}' | tail -n +2)
if [ $? -eq 0 ]; then
    echo -e "${Info}所有 Docker 容器已成功启动。"
else
    echo -e "${Error}启动 Docker 容器时发生错误，请检查。"
    exit 1
fi

echo -e "${Info}所有 Docker 容器已重新启动完成！"

echo -e "${Info}所有步骤已完成！"
