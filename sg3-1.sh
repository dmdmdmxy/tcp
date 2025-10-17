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
DOMAIN="3.aaa.sg01.yunti.best"                            # 子域名
ROOT_DOMAIN="yunti.best"                           # 主域名

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
docker run --restart=on-failure --name gw-basic-sg-36-39 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e soga_key=Ox2YKGI6WiUBNXr1ZD2Ev0Y3HrLbev9v \
-e type=sspanel-uim \
-e server_type=v2ray \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu/ \
-e webapi_key=qwer123 \
-e node_id=36,39 \
-e user_speed_limit=100 \
-e forbidden_bit_torrent=true \
-e user_tcp_limit=200 \
-e proxy_protocol=true \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=80 \
-e dy_limit_speed=50 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
-e dy_limit_white_user_id=3 \
vaxilu/soga

# 运行第二个容器
docker run --restart=on-failure --name a.sg-01-02 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=v2ray \
-e soga_key=tLlTYQC9W0j1Ihnq5d7jYI82kQbxjfYG \
-e api=webapi \
-e webapi_url=https://v2ray.yuntivpn.xyz \
-e webapi_key=NimaQu \
-e node_id=20,21 \
-e proxy_protocol=true \
-e forbidden_bit_torrent=true \
-e user_tcp_limit=200 \
-e redis_enable=true \
-e redis_addr=195.123.241.153:12345 \
-e redis_password=fgsdfgasgdfui \
-e redis_db=4 \
-e conn_limit_expiry=5 \
-e dy_limit_enable=true \
-e dy_limit_duration=20:00-24:00,00:00-02:00 \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=100 \
-e dy_limit_speed=50 \
-e dy_limit_time=600 \
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
./nezha-agent service install -s 2024.yunti.io:5555 -p tfGtl4KJckWgKfA7GQ

echo -e "${Info}Nezha 监控 Agent 安装并启动完成！"

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
