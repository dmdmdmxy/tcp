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

# 第六步：运行多个 Docker 容器
echo "开始运行多个 Docker 容器..."

# 运行第一个容器
docker run --restart=on-failure --name gw-ssr-basic01-02-03 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=ssr \
-e soga_key=JGD4m9BkddmjLqL6AZVqEhvNkf0yGTEs \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu \
-e webapi_key=qwer123 \
-e forbidden_bit_torrent=true \
-e user_tcp_limit=200 \
-e node_id=117,118,119 \
-e proxy_protocol=true \
-e forbidden_bit_torrent=true \
-e user_speed_limit=100 \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=100 \
-e dy_limit_speed=30 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
vaxilu/soga

docker run --restart=on-failure --name gw-ssr-pro01-02-03 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=ssr \
-e soga_key=JGD4m9BkddmjLqL6AZVqEhvNkf0yGTEs \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu \
-e webapi_key=qwer123 \
-e forbidden_bit_torrent=true \
-e user_tcp_limit=200 \
-e node_id=120,121,122 \
-e proxy_protocol=true \
-e forbidden_bit_torrent=true \
-e user_speed_limit=500 \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=100 \
-e dy_limit_speed=30 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
vaxilu/soga

# 运行第二个容器
docker run --restart=on-failure --name b.hk01-hk02 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=ssr \
-e soga_key=XqnhglMPQZKvkEOTVWcZKAWCPNyFhqJi \
-e api=webapi \
-e webapi_url=https://v2ray.yuntivpn.xyz \
-e webapi_key=NimaQu \
-e node_id=423,424 \
-e proxy_protocol=true \
-e forbidden_bit_torrent=true \
-e user_tcp_limit=200 \
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

# 运行第三个容器
docker run --restart=on-failure --name p.hk01-02 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=ssr \
-e soga_key=XqnhglMPQZKvkEOTVWcZKAWCPNyFhqJi \
-e api=webapi \
-e webapi_url=https://v2ray.yuntivpn.xyz \
-e webapi_key=NimaQu \
-e node_id=425,426 \
-e proxy_protocol=true \
-e auto_out_ip=true \
-e forbidden_bit_torrent=true \
-e user_tcp_limit=200 \
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

docker run --restart=on-failure --name a.hk01-02 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e type=sspanel-uim \
-e server_type=ssr \
-e soga_key=XqnhglMPQZKvkEOTVWcZKAWCPNyFhqJi \
-e api=webapi \
-e webapi_url=https://v2ray.yuntivpn.xyz \
-e webapi_key=NimaQu \
-e node_id=427,428 \
-e proxy_protocol=true \
-e auto_out_ip=true \
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

# 第七步：创建并写入配置文件
echo "开始创建并写入配置文件..."

# 确保 /etc/soga 目录存在
if [ ! -d "/etc/soga" ]; then
    mkdir -p /etc/soga
    echo "已创建目录 /etc/soga"
else
    echo "目录 /etc/soga 已存在，跳过创建。"
fi

# 创建 /etc/soga/routes.toml 文件并写入内容
cat <<EOF > /etc/soga/routes.toml
enable = true

[[routes]]
rules = [
  "geosite:netflix",
  "geosite:disney",
]
[[routes.Outs]]
listen="" 
type="ssr"
server="nnc.yuntijiasu.cloud"
port=29985
password="4wMNkIVsgybXfA2u"
cipher="chacha20-ietf"
obfs="plain"
obfs_param=""
protocol="auth_aes128_sha1"
protocol_param="206018:NBLRtS8fuklYjVd3"

#OpenAIgeminiclaude
[[routes]]
rules = [
  "domain:browser-intake-datadoghq.com",
  "domain:chat.openai.com.cdn.cloudflare.net",
  "domain:openai-api.arkoselabs.com",
  "domain:openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net",
  "domain:openaicomproductionae4b.blob.core.windows.net",
  "domain:production-openaicom-storage.azureedge.net",
  "domain:static.cloudflareinsights.com",
  "domain:openai.com",
  "domain:chat.openai.com",
  "domain:challenges.cloudflare.com",
  "domain:auth0.openai.com",
  "domain:platform.openai.com",
  "domain:ai.com",
  "domain:chatgpt.com",
  "domain:oaiusercontent.com",
  "domain:otokyo1a.turn.livekit.cloud",
  "domain:media.giphy.com",
  "domain:i1.wp.com",
  "domain:s.gravatar.com",
  "domain:api.revenuecat.com",
  "domain:auth0.com",
  "domain:o33249.ingest.sentry.io",
  "domain:oaistatic.com",
  "domain:featureassets.org",
  "domain:prodregistryv2.org",

  "domain-suffix:ai.com",
  "domain-suffix:algolia.net",
  "domain-suffix:api.statsig.com",
  "domain-suffix:auth0.com",
  "domain-suffix:chatgpt.com",
  "domain-suffix:chatgpt.livekit.cloud",
  "domain-suffix:client-api.arkoselabs.com",
  "domain-suffix:events.statsigapi.net",
  "domain-suffix:featuregates.org",
  "domain-suffix:host.livekit.cloud",
  "domain-suffix:identrust.com",
  "domain-suffix:intercom.io",
  "domain-suffix:intercomcdn.com",
  "domain-suffix:launchdarkly.com",
  "domain-suffix:oaistatic.com",
  "domain-suffix:oaiusercontent.com",
  "domain-suffix:observeit.net",
  "domain-suffix:openai.com",
  "domain-suffix:openaiapi-site.azureedge.net",
  "domain-suffix:openaicom.imgix.net",
  "domain-suffix:segment.io",
  "domain-suffix:sentry.io",
  "domain-suffix:stripe.com",
  "domain-suffix:turn.livekit.cloud",

  "domain:cdn.usefathom.com",
  "domain-suffix:anthropic.com",
  "domain-suffix:claude.ai",
  "domain:ai.google.dev",
  "domain:alkalimakersuite-pa.clients6.google.com",
  "domain:makersuite.google.com",
  "domain-suffix:bard.google.com",
  "domain-suffix:deepmind.com",
  "domain-suffix:deepmind.google",
  "domain-suffix:gemini.google.com",
  "domain-suffix:generativeai.google",
  "domain-suffix:proactivebackend-pa.googleapis.com",
  "domain-suffix:apis.google.com",
  "domain-keyword:colab",
  "domain-keyword:developerprofiles",
  "domain-keyword:generativelanguage"
]
[[routes.Outs]]
type = "ssr"
server = "us-ai01.yunti.io"
port = 29991
password = "4wMNkIVsgybXfA2u"
cipher = "chacha20-ietf"
protocol = "auth_aes128_sha1"
protocol_param = "206018:NBLRtS8fuklYjVd3"
obfs = "plain"
obfs_param = ""

[[routes.Outs]]
type = "ssr"
server = "us-ai02.yunti.io"
port = 29992
password = "4wMNkIVsgybXfA2u"
cipher = "chacha20-ietf"
protocol = "auth_aes128_sha1"
protocol_param = "206018:NBLRtS8fuklYjVd3"
obfs = "plain"
obfs_param = ""


[[routes]]
rules = [
 "domain:scholar.google.com",
  "domain-suffix:1lib.cloud",
  "domain-suffix:1lib.domains",
  "domain-suffix:1lib.education",
  "domain-suffix:1lib.eu",
  "domain-suffix:1lib.limited",
  "domain-suffix:1lib.pl",
  "domain-suffix:1lib.to",
  "domain-suffix:1lib.tw",
  "domain-suffix:2lib.org",
  "domain-suffix:3lib.net",
  "domain-suffix:aclweb.org",
  "domain-suffix:acm.org",
  "domain-suffix:acs.org",
  "domain-suffix:aiaa.org",
  "domain-suffix:aip.org",
  "domain-suffix:altmetric.com",
  "domain-suffix:amamanualofstyle.com",
  "domain-suffix:ams.org",
  "domain-suffix:analytictech.com",
  "domain-suffix:anb.org",
  "domain-suffix:annualreviews.org",
  "domain-suffix:apa.org",
  "domain-suffix:apress.com",
  "domain-suffix:aps.org",
  "domain-suffix:art1lib.com",
  "domain-suffix:arxiv.org",
  "domain-suffix:ascelibrary.org",
  "domain-suffix:asha.org",
  "domain-suffix:asm.org",
  "domain-suffix:asme.org",
  "domain-suffix:astm.org",
  "domain-suffix:b-ok.africa",
  "domain-suffix:b-ok.asia",
  "domain-suffix:b-ok.cc",
  "domain-suffix:b-ok.global",
  "domain-suffix:b-ok.org",
  "domain-suffix:berkeley.edu",
  "domain-suffix:biomedcentral.com",
  "domain-suffix:biorxiv.org",
  "domain-suffix:blackstonespoliceservice.com",
  "domain-suffix:blackwell-synergy.com",
  "domain-suffix:bmj.com",
  "domain-suffix:book4you.org",
  "domain-suffix:bookfi.net",
  "domain-suffix:booksc.eu",
  "domain-suffix:booksc.me",
  "domain-suffix:booksc.org",
  "domain-suffix:booksc.xyz",
  "domain-suffix:bookshome.info",
  "domain-suffix:bookshome.net",
  "domain-suffix:bookshome.world",
  "domain-suffix:brill.com",
  "domain-suffix:cabdirect.org",
  "domain-suffix:cambridge.org",
  "domain-suffix:cambridgedigital.net",
  "domain-suffix:cambridgemaths.org",
  "domain-suffix:cambridgeschoolshakespeare.com",
  "domain-suffix:cas.org",
  "domain-suffix:cell.com",
  "domain-suffix:clarivate.com",
  "domain-suffix:cnki.net",
  "domain-suffix:computer.org",
  "domain-suffix:computingreviews.com",
  "domain-suffix:cqvip.com",
  "domain-suffix:crossref.org",
  "domain-suffix:csiro.au",
  "domain-suffix:de1lib.org",
  "domain-suffix:deepdyve.com",
  "domain-suffix:degruyter.com",
  "domain-suffix:dentalhypotheses.com",
  "domain-suffix:doi.info",
  "domain-suffix:doi.org",
  "domain-suffix:ebscohost.com",
  "domain-suffix:elifesciences.org",
  "domain-suffix:els-cdn.com",
  "domain-suffix:elsevier-ae.com",
  "domain-suffix:elsevier.com",
  "domain-suffix:elsevier.io",
  "domain-suffix:emerald.com",
  "domain-suffix:endnote.com",
  "domain-suffix:engineeringvillage.com",
  "domain-suffix:epigeum.com",
  "domain-suffix:europepmc.org",
  "domain-suffix:evise.com",
  "domain-suffix:frontiersin.org",
  "domain-suffix:gale.com",
  "domain-suffix:galegroup.com",
  "domain-suffix:geoscienceworld.org",
  "domain-suffix:ggsrv.com",
  "domain-suffix:hindawi.com",
  "domain-suffix:hk1lib.org",
  "domain-suffix:ic.ac.uk",
  "domain-suffix:icevirtuallibrary.com",
  "domain-suffix:ieee.org",
  "domain-suffix:ieeecomputer.org",
  "domain-suffix:ieeecomputersociety.org",
  "domain-suffix:imf.org",
  "domain-suffix:imperial.ac.uk",
  "domain-suffix:imperial.insendi.com",
  "domain-suffix:imperialbusiness.school",
  "domain-suffix:informs.org",
  "domain-suffix:iop.org",
  "domain-suffix:isca-speech.org",
  "domain-suffix:isiknowledge.com",
  "domain-suffix:jamanetwork.com",
  "domain-suffix:japanknowledge.com",
  "domain-suffix:jbc.org",
  "domain-suffix:jbe-platform.com",
  "domain-suffix:jhu.edu",
  "domain-suffix:jmlr.org",
  "domain-suffix:jneurosci.org",
  "domain-suffix:jstor.org",
  "domain-suffix:karger.com",
  "domain-suffix:knovel.com",
  "domain-suffix:kuke.com",
  "domain-suffix:lawdata.com.tw",
  "domain-suffix:libguides.com",
  "domain-suffix:libsolutions.app",
  "domain-suffix:libsolutions.domains",
  "domain-suffix:libsolutions.net",
  "domain-suffix:liebertpub.com",
  "domain-suffix:literatumonline.com",
  "domain-suffix:ma1lib.org",
  "domain-suffix:madsrevolution.net",
  "domain-suffix:mdpi.com",
  "domain-suffix:mit",
  "domain-suffix:mit.edu",
  "domain-suffix:mit.net",
  "domain-suffix:mitpressjournals.org",
  "domain-suffix:mpg.de",
  "domain-suffix:myilibrary.com",
  "domain-suffix:nature.com",
  "domain-suffix:ncbi.nlm.nih.gov",
  "domain-suffix:nejm.org",
  "domain-suffix:neurology.org",
  "domain-suffix:newisiknowledge.com",
  "domain-suffix:oecd-ilibrary.org",
  "domain-suffix:oed.com",
  "domain-suffix:omscr.com",
  "domain-suffix:osapublishing.org",
  "domain-suffix:oup.com",
  "domain-suffix:ouplaw.com",
  "domain-suffix:ovid.com",
  "domain-suffix:ox.ac.uk",
  "domain-suffix:oxfordaasc.com",
  "domain-suffix:oxfordartonline.com",
  "domain-suffix:oxfordbibliographies.com",
  "domain-suffix:oxfordclinicalpsych.com",
  "domain-suffix:oxforddnb.com",
  "domain-suffix:oxfordfirstsource.com",
  "domain-suffix:oxfordhandbooks.com",
  "domain-suffix:oxfordlawtrove.com",
  "domain-suffix:oxfordmedicine.com",
  "domain-suffix:oxfordmusiconline.com",
  "domain-suffix:oxfordpoliticstrove.com",
  "domain-suffix:oxfordre.com",
  "domain-suffix:oxfordreference.com",
  "domain-suffix:oxfordscholarlyeditions.com",
  "domain-suffix:oxfordscholarship.com",
  "domain-suffix:oxfordwesternmusic.com",
  "domain-suffix:peerj.com",
  "domain-suffix:physiology.org",
  "domain-suffix:pkulaw.com",
  "domain-suffix:plos.org",
  "domain-suffix:pnas.org",
  "domain-suffix:princeton.edu",
  "domain-suffix:proquest.com",
  "domain-suffix:psyccareers.com",
  "domain-suffix:readcube.com",
  "domain-suffix:researchgate.net",
  "domain-suffix:routledgehandbooks.com",
  "domain-suffix:royalsocietypublishing.org",
  "domain-suffix:rsc.org",
  "domain-suffix:sagepub.com",
  "domain-suffix:scholarpedia.org",
  "domain-suffix:sci-hub.tw",
  "domain-suffix:science.org",
  "domain-suffix:sciencedirect.com",
  "domain-suffix:sciencedirectassets.com",
  "domain-suffix:sciencemag.org",
  "domain-suffix:sciencenets.com",
  "domain-suffix:scientificamerican.com",
  "domain-suffix:scitation.org",
  "domain-suffix:scopus.com",
  "domain-suffix:semanticscholar.org",
  "domain-suffix:serialssolutions.com",
  "domain-suffix:sg1lib.org",
  "domain-suffix:siam.org",
  "domain-suffix:silverchair-cdn.com",
  "domain-suffix:singlelogin.app",
  "domain-suffix:singlelogin.me",
  "domain-suffix:sipriyearbook.org",
  "domain-suffix:spiedigitallibrary.org",
  "domain-suffix:springer.com",
  "domain-suffix:springerlink.com",
  "domain-suffix:springernature.com",
  "domain-suffix:statsmakemecry.com",
  "domain-suffix:tandf.co.uk",
  "domain-suffix:tandfonline.com",
  "domain-suffix:taylorandfrancis.com",
  "domain-suffix:taylorfrancis.com",
  "domain-suffix:thelancet.com",
  "domain-suffix:turnitin.com",
  "domain-suffix:uchicago.edu",
  "domain-suffix:ucla.edu",
  "domain-suffix:ukwhoswho.com",
  "domain-suffix:umass.edu",
  "domain-suffix:un.org",
  "domain-suffix:uni-bielefeld.de",
  "domain-suffix:universitypressscholarship.com",
  "domain-suffix:uq.edu.au",
  "domain-suffix:uq.h5p.com",
  "domain-suffix:veryshortintroductions.com",
  "domain-suffix:wanfangdata.com",
  "domain-suffix:wanfangdata.com.cn",
  "domain-suffix:webofknowledge.com",
  "domain-suffix:webofscience.com",
  "domain-suffix:westlaw.com",
  "domain-suffix:westlawchina.com",
  "domain-suffix:wiley.com",
  "domain-suffix:wkap.nl",
  "domain-suffix:worldbank.org",
  "domain-suffix:worldscientific.com",
  "domain-suffix:yale.edu",
  "domain-suffix:z-lib.org",
  "domain-suffix:zlib.life",
  "domain-suffix:zlibcdn.com",
  "domain-suffix:zlibcdn2.com",
  "domain-suffix:zotero.org",

# Now E
  "domain:nowe.com",
  "domain:nowestatic.com",
  # Now TV
  "domain:now.com",
  # Viu.TV
  "domain:viu.now.com",
  "domain:viu.tv",
  # MyTVSuper
  "domain:mytvsuper.com",
  "domain:mytvsuperlimited.hb.omtrdc.net",
  "domain:mytvsuperlimited.sc.omtrdc.net",
  "domain:tvb.com",
  # HOY TV
  "domain:hoy.tv",
  # BiliBili
  "domain:bilibili.com",
]
[[routes.Outs]]
listen="" 
type="ssr"
server="hkbn-500m-01.yuntijiasu.cloud"
port=29981
password="4wMNkIVsgybXfA2u"
cipher="chacha20-ietf"
obfs="plain"
obfs_param=""
protocol="auth_aes128_sha1"
protocol_param="206018:NBLRtS8fuklYjVd3"

[[routes.Outs]]
listen="" 
type="ssr"
server="hkbn-500m-02.yuntijiasu.cloud"
port=29982
password="4wMNkIVsgybXfA2u"
cipher="chacha20-ietf"
obfs="plain"
obfs_param=""
protocol="auth_aes128_sha1"
protocol_param="206018:NBLRtS8fuklYjVd3"

[[routes.Outs]]
listen="" 
type="ssr"
server="hgc-500m-01.yuntijiasu.cloud"
port=29983
password="4wMNkIVsgybXfA2u"
cipher="chacha20-ietf"
obfs="plain"
obfs_param=""
protocol="auth_aes128_sha1"
protocol_param="206018:NBLRtS8fuklYjVd3"

[[routes.Outs]]
listen="" 
type="ssr"
server="hgc-500m-02.yuntijiasu.cloud"
port=29984
password="4wMNkIVsgybXfA2u"
cipher="chacha20-ietf"
obfs="plain"
obfs_param=""
protocol="auth_aes128_sha1"
protocol_param="206018:NBLRtS8fuklYjVd3"

[[routes]]
rules = ["*"]

[[routes.Outs]]
type = "direct"
EOF

if [ $? -eq 0 ]; then
    echo "文件 /etc/soga/routes.toml 已成功创建并写入内容。"
else
    echo "创建 /etc/soga/routes.toml 失败！"
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

# 创建定时任务，每分钟检测并更新 DDNS
echo "创建定时任务，每分钟检测 IP 并更新 DDNS..."
crontab -l 2>/dev/null | grep -v "cloudflare_ddns.sh" > /tmp/crontab.tmp
echo "* * * * * /bin/bash /path/to/this/script.sh >> /var/log/cloudflare_ddns.log 2>&1" >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp && rm -f /tmp/crontab.tmp
log "${Info} 定时任务已创建！"

# 调用 DDNS 更新函数
update_ddns

echo -e "${Info} 所有步骤已完成，请根据需要重启服务器。"
