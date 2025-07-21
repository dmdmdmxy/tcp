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
DOMAIN="1.aaa-jp02.yunti.best"                            # 子域名
ROOT_DOMAIN="yunti.best"                           # 主域名

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
-e user_tcp_limit=200 \
-e proxy_protocol=true \
-e user_speed_limit=500 \
-e forbidden_bit_torrent=true \
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
./nezha-agent service install -s 15.235.144.68:5555 -p GEvQexVxTAaqfxMm4J

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

# 创建 /etc/soga/routes.toml 文件并写入内容
cat <<EOF > /etc/soga/routes.toml
enable = true

# nf/ds/hulu
[[routes]]
rules = [
  "geosite:netflix",
  "geosite:disney",
  "geosite:hulu",


[[routes.Outs]]
listen = ""
type = "ss"
server = "nf-disney-jp.ytjscloud.com"
port = 4610
password = "D2AmLZIWlMulG5ki"
cipher = "aes-128-gcm"

# hbomax
[[routes]]
rules = [
 "domain-suffix:bcbolthboa-a.akamaihd.net",
  "domain-suffix:cf-images.ap-southeast-1.prod.boltdns.net",
  "domain-suffix:cinemax.com",
  "domain-suffix:dai3fd1oh325y.cloudfront.net",
  "domain-suffix:execute-api.ap-southeast-1.amazonaws.com",
  "domain-suffix:execute-api.us-east-1.amazonaws.com",
  "domain-suffix:forthethrone.com",
  "domain-suffix:hbo.com",
  "domain-suffix:hbo.com.c.footprint.net",
  "domain-suffix:hbo.com.edgesuite.net",
  "domain-suffix:hbo.map.fastly.net",
  "domain-suffix:hboasia.com",
  "domain-suffix:hboasia1-i.akamaihd.net",
  "domain-suffix:hboasia2-i.akamaihd.net",
  "domain-suffix:hboasia3-i.akamaihd.net",
  "domain-suffix:hboasia4-i.akamaihd.net",
  "domain-suffix:hboasia5-i.akamaihd.net",
  "domain-suffix:hboasialive.akamaized.net",
  "domain-suffix:hbogeo.cust.footprint.net",
  "domain-suffix:hbogo.co.th",
  "domain-suffix:hbogo.com",
  "domain-suffix:hbogo.eu",
  "domain-suffix:hbogoasia.com",
  "domain-suffix:hbogoasia.hk",
  "domain-suffix:hbogoasia.id",
  "domain-suffix:hbogoasia.ph",
  "domain-suffix:hbogoasia.sg",
  "domain-suffix:hbogoasia.tw",
  "domain-suffix:hbogoprod-vod.akamaized.net",
  "domain-suffix:hbolb.onwardsmg.com",
  "domain-suffix:hbomax.com",
  "domain-suffix:hbomaxcdn.com",
  "domain-suffix:hbomaxdash.s.llnwi.net",
  "domain-suffix:hbonow.com",
  "domain-suffix:hbounify-prod.evergent.com",
  "domain-suffix:manifest.prod.boltdns.net",
  "domain-suffix:max.com",
  "domain-suffix:maxgo.com",
  "domain-suffix:now-ashare.com",
  "domain-suffix:now-tv.com",
  "domain-suffix:now.com",
  "domain-suffix:now.com.hk",
  "domain-suffix:nowe.com",
  "domain-suffix:nowe.hk",
  "domain-suffix:players.brightcove.net",
  "domain-suffix:warnermediacdn.com",
  "domain-suffix:youboranqs01.com",

#temu
  "domain:temu.com",
  "domain-suffix:temu.com",
  "domain:api.temu.com",
  "domain:app.temu.com",
  "domain:ads.temu.com",
  "domain:global.temu.com",
  "domain:us.temu.com",
  "domain:uk.temu.com",
  "domain:es.temu.com",
  "domain:de.temu.com",
  "domain:fr.temu.com",
  "domain:pt.temu.com",
  "domain:ca.temu.com",
  "domain:jp.temu.com",
  "domain:it.temu.com",
  "domain:mx.temu.com",
  "domain:jobs.temu.com",
  "domain:share.temu.com",
  "domain:partner.temu.com",
  "domain:docs.temu.com",
  "domain:research.temu.com",
  "domain:qa.temu.com",

#流媒体
  "domain:nhk.jp",
  "domain:nhk.or.jp",
  "domain:dmm-extension.com",
  "domain:dmm.co.jp",
  "domain:dmm.com",
  "domain:videomarket.jp",
  "domain:p-smith.com",
  "domain:vmdash-cenc.akamaized.net",
  "domain:img.vm-movie.jp",
  "domain:abema.io",
  "domain:abema.tv",
  "domain:ds-linear-abematv.akamaized.net",
  "domain:linear-abematv.akamaized.net",
  "domain:ds-vod-abematv.akamaized.net",
  "domain:vod-abematv.akamaized.net",
  "domain:vod-playout-abematv.akamaized.net",
  "domain:ameba.jp",
  "domain:hayabusa.io",
  "domain:bucketeer.jp",
  "domain:abema.adx.promo",
  "domain:hayabusa.media",
  "domain:abema-tv.com",
  "domain:dmc.nico",
  "domain:nicovideo.jp",
  "domain:nimg.jp",
  "domain:telasa.jp",
  "domain:kddi-video.com",
  "domain:videopass.jp",
  "domain:d2lmsumy47c8as.cloudfront.net",
]

[[routes.Outs]]
listen = ""
type = "ssr"
server = "jp.dmm.yunti.io"
port = 29993
password = "4wMNkIVsgybXfA2u"
cipher = "chacha20-ietf"
protocol = "auth_aes128_sha1"
protocol_param = "206018:NBLRtS8fuklYjVd3"
obfs = "plain"
obfs_param = ""


# 谷歌学术
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
]

[[routes.Outs]]
listen = ""
type = "vmess"
server = "hkt-1g-03.yuntijiasu.cloud"
port = 18280
uuid = "b4063130-2621-3834-b62b-88bcce19b924"
alter_id = 0
network = "tcp"
tls = false

[[routes.Outs]]
listen = ""
type = "vmess"
server = "hkbn-500m-01.yuntijiasu.cloud"
port = 18280
uuid = "b4063130-2621-3834-b62b-88bcce19b924"
alter_id = 0
network = "tcp"
tls = false

[[routes.Outs]]
listen = ""
type = "vmess"
server = "hkbn-500m-02.yuntijiasu.cloud"
port = 18280
uuid = "b4063130-2621-3834-b62b-88bcce19b924"
alter_id = 0
network = "tcp"
tls = false

[[routes.Outs]]
listen = ""
type = "vmess"
server = "hgc-500m-01.yuntijiasu.cloud"
port = 21555
uuid = "b4063130-2621-3834-b62b-88bcce19b924"
alter_id = 0
network = "tcp"
tls = false

[[routes.Outs]]
listen = ""
type = "ssr"
server = "icable-500m-01.yuntijiasu.cloud"
port = 57420
password = "4wMNkIVsgybXfA2u"
cipher = "chacha20-ietf"
protocol = "auth_aes128_sha1"
protocol_param = "206018:NBLRtS8fuklYjVd3"
obfs = "plain"
obfs_param = ""

[[routes.Outs]]
listen = ""
type = "vmess"
server = "hgc-500m-02.yuntijiasu.cloud"
port = 21937
uuid = "b4063130-2621-3834-b62b-88bcce19b924"
alter_id = 0
network = "tcp"
tls = false


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

echo -e "${Info}配置文件已成功创建并写入！"

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
