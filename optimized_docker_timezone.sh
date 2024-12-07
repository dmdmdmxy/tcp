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

# 第一步：设置网络优化参数
echo "正在配置网络优化参数..."

# 写入网络优化配置
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

# 内存交换设置
vm.swappiness = 10

# 文件描述符限制
fs.file-max = 6553560
EOF

# 使配置生效
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

# 重启 Docker 服务
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

echo -e "${Info}所有步骤已完成！"
