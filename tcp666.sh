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
if sysctl -p; then
    echo "内核参数优化完成！"
else
    echo -e "${Error}内核参数优化加载失败！"
    exit 1
fi

# 2. 调整 ulimit 文件描述符限制
echo "调整文件描述符限制..."
{
    echo "* soft nofile 1048576"
    echo "* hard nofile 1048576"
    echo "* soft nproc 1048576"
    echo "* hard nproc 1048576"
} >> /etc/security/limits.conf

# 3. 调整 systemd 资源限制
echo "调整 systemd 资源限制..."
{
    echo "DefaultLimitNOFILE=1048576"
    echo "DefaultLimitNPROC=1048576"
} >> /etc/systemd/system.conf

{
    echo "DefaultLimitNOFILE=1048576"
    echo "DefaultLimitNPROC=1048576"
} >> /etc/systemd/user.conf

# 立即生效 systemd 配置
systemctl daemon-reexec

echo "优化完成！"

# 第三步：配置系统时区
echo "开始配置系统时区为 Asia/Shanghai..."
echo "Asia/Shanghai" > /etc/timezone
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

if [ $? -eq 0 ]; then
    echo -e "${Info}系统时区已成功配置为 Asia/Shanghai。"
else
    echo -e "${Error}时区配置失败，请手动检查配置文件。"
fi

echo -e "${Info}所有步骤已完成！正在重启系统..."
read -p "你确定要重启系统吗？ (y/n) " -n 1 -r
echo    # 在同一行后换行
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
else
    echo "重启已取消。"
fi
