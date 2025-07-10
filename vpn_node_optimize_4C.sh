#!/bin/bash
# 融合优化脚本 for VPN 落地服务器（4C / 8G / 1Gbps）

set -e

echo "[INFO] 写入 sysctl 参数..."
cat > /etc/sysctl.d/99-vpn-opt.conf <<EOF
# BBR + FastOpen
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# TCP 性能优化
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.core.optmem_max = 4194304
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 8388608 8388608 8388608
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# UDP 最小缓冲
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# VPN 必要：开启转发
net.ipv4.ip_forward = 1

# conntrack 追踪连接优化
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 180
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF

sysctl --system

echo "[INFO] 设置 ulimit 文件描述符限制..."
sed -i '/nofile/d;/nproc/d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

# 确保 PAM 模块启用 limits
if ! grep -q pam_limits.so /etc/pam.d/common-session; then
  echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

echo "[INFO] 设置 systemd 限制..."
sed -i '/^DefaultLimitNOFILE/d' /etc/systemd/system.conf
echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
sed -i '/^DefaultLimitNPROC/d' /etc/systemd/system.conf
echo "DefaultLimitNPROC=1048576" >> /etc/systemd/system.conf

sed -i '/^DefaultLimitNOFILE/d' /etc/systemd/user.conf
echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/user.conf
sed -i '/^DefaultLimitNPROC/d' /etc/systemd/user.conf
echo "DefaultLimitNPROC=1048576" >> /etc/systemd/user.conf

systemctl daemon-reexec

echo "[INFO] 安装 conntrack 工具（如未安装）..."
apt-get update -qq && apt-get install -y conntrack

echo "[INFO] 创建 conntrack 清理脚本..."
cat > /usr/local/bin/conntrack_cleanup.sh <<'CLEAN'
#!/bin/bash
conntrack -D -p tcp --state FIN_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state TIME_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state CLOSE_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state SYN_SENT > /dev/null 2>&1
echo "[`date`] cleaned conntrack" >> /var/log/conntrack_cleanup.log
CLEAN

chmod +x /usr/local/bin/conntrack_cleanup.sh

echo "[INFO] 设置 crontab 定时任务..."
(crontab -l 2>/dev/null; echo "*/2 * * * * /usr/local/bin/conntrack_cleanup.sh") | crontab -

echo "[✅ 完成] 优化完成，请重启后确认 ulimit 和连接性能生效。"
