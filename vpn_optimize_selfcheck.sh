#!/bin/bash
# VPN 优化参数部署自检 & 自动修复脚本

echo "🔧 VPN 自检开始..."

# 1. 检查 ulimit
echo -n "📌 [1/6] 检查文件描述符限制："
ULIM=$(ulimit -n)
if [ "$ULIM" -ge 65535 ]; then
    echo "✅ 当前为 $ULIM，已合格"
else
    echo "❌ 当前为 $ULIM，未生效"
    echo "⚠️ 请确认 limits.conf、system.conf 修改后已重新登录或重启"
fi

# 2. 检查 conntrack 参数
echo -n "📌 [2/6] 检查 conntrack 参数："
CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max)
if [ "$CT_MAX" -ge 262144 ]; then
    echo "✅ nf_conntrack_max = $CT_MAX"
else
    echo "❌ nf_conntrack_max = $CT_MAX，不足"
    echo "⚠️ 请确认 sysctl 设置已正确写入并 sysctl --system 应用"
fi

# 3. 检查清理脚本存在
echo -n "📌 [3/6] 检查 conntrack 清理脚本："
if [ -f /usr/local/bin/conntrack_cleanup.sh ]; then
    echo "✅ 存在"
else
    echo "❌ 不存在，自动创建中..."
    cat > /usr/local/bin/conntrack_cleanup.sh <<'EOF'
#!/bin/bash
conntrack -D -p tcp --state FIN_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state TIME_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state CLOSE_WAIT > /dev/null 2>&1
conntrack -D -p tcp --state SYN_SENT > /dev/null 2>&1
echo "[`date`] cleaned conntrack" >> /var/log/conntrack_cleanup.log
EOF
    chmod +x /usr/local/bin/conntrack_cleanup.sh
    echo "✅ 已修复"
fi

# 4. 检查 crontab 是否包含清理任务
echo -n "📌 [4/6] 检查 crontab 定时任务："
if crontab -l 2>/dev/null | grep -q conntrack_cleanup.sh; then
    echo "✅ 已添加"
else
    echo "❌ 未添加，自动写入中..."
    (crontab -l 2>/dev/null; echo "*/2 * * * * /usr/local/bin/conntrack_cleanup.sh") | crontab -
    echo "✅ 已修复"
fi

# 5. 检查 GitHub 脚本是否含 CRLF
echo -n "📌 [5/6] 检查下载脚本换行符（CRLF）："
if file vpn_node_optimize_fusion.sh 2>/dev/null | grep -q CRLF; then
    echo "⚠️ 存在 Windows CRLF，自动转换为 UNIX 格式"
    apt-get install -y dos2unix >/dev/null 2>&1
    dos2unix vpn_node_optimize_fusion.sh >/dev/null 2>&1
    echo "✅ 已转换"
else
    echo "✅ 格式正常（LF）"
fi

# 6. 检查 conntrack 工具安装
echo -n "📌 [6/6] 检查 conntrack 工具："
if ! command -v conntrack >/dev/null; then
    echo "❌ 未安装，自动安装中..."
    apt-get update -qq && apt-get install -y conntrack
else
    echo "✅ 已安装"
fi

echo -e "\n🎉 自检完毕，请重启 SSH session 以确保 limits 生效。"
