#!/usr/bin/env bash
# setup_all_in_one.sh：融合两个脚本，执行系统初始化 + DDNS + Docker + soga
set -euo pipefail

# ========== 1. 配置项 ==========
DDNS_RAW_URL="https://raw.githubusercontent.com/dmdmdmxy/ddns/refs/heads/main/pass-hk01-DNS.sh"
DDNS_SCRIPT_TARGET="/usr/local/bin/ddns_update.sh"
INSTALL_SH_URL="http://ytpass.fxscloud.com:666/client/AKS0E00LBr4J5rXj/install.sh"
CRON_SCHEDULE="*/1 * * * *"
LOG_FILE="/var/log/cloudflare_ddns.log"
TZ_REGION="Asia/Shanghai"

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ========== 2. 基础准备 ==========
ensure_root() {
    [[ "$EUID" -ne 0 ]] && { echo "请使用 root 用户运行此脚本"; exit 1; }
}

ensure_package() {
    local pkg="$1"
    command -v "$pkg" &>/dev/null && return
    log "安装依赖：$pkg"
    if [[ -f /etc/debian_version ]]; then
        apt-get update -y && apt-get install -y "$pkg"
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y "$pkg"
    elif command -v apk >/dev/null; then
        apk add --no-cache "$pkg"
    fi
}

ensure_cron_ready() {
    ensure_package crontab || true
    systemctl enable --now cron || systemctl enable --now crond || true
}

create_cron_entry() {
    ensure_cron_ready
    local CRON_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    local cron_line="${CRON_SCHEDULE} /usr/bin/env -i PATH=${CRON_PATH} /bin/bash \"${DDNS_SCRIPT_TARGET}\" >> \"${LOG_FILE}\" 2>&1"
    {
        crontab -l 2>/dev/null | grep -Fv "$DDNS_SCRIPT_TARGET" || true
        echo "$cron_line"
    } | crontab -
    log "已添加 cron 定时任务：$cron_line"
}

# ========== 3. 初始化任务 ==========
ensure_root

log "准备日志文件..."
touch "$LOG_FILE" && chmod 644 "$LOG_FILE"

log "安装依赖..."
ensure_package jq
ensure_package wget

log "优化 sysctl 网络参数..."
cat <<EOF > /etc/sysctl.d/99-ec2.conf
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
sysctl --system

log "设置系统文件描述符限制..."
cat <<EOF >> /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF
cat <<EOF >> /etc/systemd/system.conf
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
cat <<EOF >> /etc/systemd/user.conf
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
systemctl daemon-reexec

log "配置时区..."
if command -v timedatectl &>/dev/null; then
    timedatectl set-timezone "$TZ_REGION"
else
    ln -sf /usr/share/zoneinfo/"$TZ_REGION" /etc/localtime
    echo "$TZ_REGION" > /etc/timezone
fi

log "执行 install.sh 安装..."
wget -O /tmp/install.sh --no-check-certificate "$INSTALL_SH_URL"
chmod +x /tmp/install.sh && bash /tmp/install.sh && rm -f /tmp/install.sh

log "部署 ddns_update.sh 并执行一次..."
wget -O "$DDNS_SCRIPT_TARGET" --no-check-certificate "$DDNS_RAW_URL"
chmod +x "$DDNS_SCRIPT_TARGET"
bash "$DDNS_SCRIPT_TARGET" || log "ddns_update.sh 执行失败"
create_cron_entry

# ========== 4. Docker 安装 & 启动容器 ==========
log "安装 Docker（如未安装）..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | bash
    service docker restart || systemctl restart docker
else
    log "Docker 已安装，跳过安装。"
fi

log "运行 soga 容器（共 5 个）..."
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

log "重启所有 Docker 容器..."
docker stop $(docker ps -aq) || true
docker start $(docker ps -aq) || true

log "✅ 所有操作已完成。系统初始化 + DDNS + Docker soga 成功部署！"
