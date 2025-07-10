#!/bin/bash
# VPN 落地节点优化（4核 / 8GB）

set -e

echo "[INFO] 写入 sysctl 参数..."
cat > /etc/sysctl.d/99-vpn-opt.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 500000
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_mem = 8388608 8388608 8388608
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 180
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.ipv4.ip_forward = 1
EOF

sysctl --system

echo "[INFO] 设置文件句柄上限..."
sed -i '/nofile/d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
EOF

if ! grep -q pam_limits.so /etc/pam.d/common-session; then
  echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

echo "[INFO] 安装 conntrack 工具（如果未安装）..."
apt-get update -qq && apt-get install -y conntrack

echo "[INFO] 创建清理脚本..."
cat > /usr/local/bin/conntrack_cleanup.sh <<'CLEAN'
#!/bin/bash
conntrack -D -p tcp --state FIN_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state TIME_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state CLOSE_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state SYN_SENT > /dev/null 2>&1
echo "[`date`] cleaned conntrack" >> /var/log/conntrack_cleanup.log
CLEAN

chmod +x /usr/local/bin/conntrack_cleanup.sh

echo "[INFO] 添加定时任务..."
(crontab -l 2>/dev/null; echo "*/2 * * * * /usr/local/bin/conntrack_cleanup.sh") | crontab -

echo "[✅ 完成] VPN 落地节点优化完成。建议重启后查看效果。"
