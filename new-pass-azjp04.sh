#!/usr/bin/env bash
#
# setup_ec2.sh（含自动写入定时任务）
# 功能：
#   1. 确保以 root 身份运行
#   2. 安装 jq、wget
#   3. 优化 sysctl 和 file limits
#   4. 配置系统时区为 Asia/Shanghai
#   5. 下载并执行原有的 install.sh
#   6. 从 GitHub 拉取 ddns_update.sh 到 /usr/local/bin，并赋予可执行权限
#   7. 自动将 ddns_update.sh 加入 root 的 crontab（每 5 分钟执行一次），并把日志写到 /var/log/cloudflare_ddns.log
#
# 使用方法：
#   chmod +x setup_ec2.sh
#   sudo ./setup_ec2.sh
#
# 之后，脚本会立即执行一次 ddns_update.sh；并且在 crontab 中添加条目，以后每 5 分钟自动更新 DDNS。

set -euo pipefail

#############################
# ======= 配置区域 =======
#############################

# 1. ddns_update.sh 在 GitHub 上的 Raw 地址：
DDNS_RAW_URL="https://raw.githubusercontent.com/dmdmdmxy/tcp/main/az-jp04-DNS.sh"

# 2. 下载后放置的目标路径：
DDNS_SCRIPT_TARGET="/usr/local/bin/ddns_update.sh"

# 3. 原 install.sh 脚本下载地址（保持原先逻辑不变）：
INSTALL_SH_URL="http://ytpass.fxscloud.com:666/client/ZenPrWV1y8MmO08O/install.sh"

# 4. 定时任务表达式，这里示例每 5 分钟执行一次。
#    如果要改成每分钟执行，将 "*/5" 改为 "*/1" 即可。
CRON_SCHEDULE="*/1 * * * *"

# 5. 日志文件路径（ddns 更新脚本会将日志写入此文件）
LOG_FILE="/var/log/cloudflare_ddns.log"

#############################
# ======== 函数区 =========
#############################

log() {
    # 把带时间戳的消息输出到屏幕并追加到 LOG_FILE
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

ensure_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "【错误】请使用 root 用户运行此脚本！"
        exit 1
    fi
}

ensure_jq() {
    if ! command -v jq &>/dev/null; then
        log "【信息】检测到 jq 未安装，尝试自动安装..."
        if [[ -f /etc/debian_version ]]; then
            apt-get update -y && apt-get install -y jq
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y epel-release && yum install -y jq
        else
            log "【错误】无法自动安装 jq，请手动安装后重试。"
            exit 1
        fi
        log "【信息】jq 安装完成。"
    fi
}

ensure_wget() {
    if ! command -v wget &>/dev/null; then
        log "【信息】检测到 wget 未安装，尝试自动安装..."
        if [[ -f /etc/debian_version ]]; then
            apt-get update -y && apt-get install -y wget
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y wget
        else
            log "【错误】无法自动安装 wget，请手动安装后重试。"
            exit 1
        fi
        log "【信息】wget 安装完成。"
    fi
}

create_cron_entry() {
    # 把 ddns_update.sh 写入 root 的 crontab
    # 格式：<分 时 日 月 周> <命令>
    # 由于是 root 的 crontab，行内格式不需要指定用户字段
    local cron_line="${CRON_SCHEDULE} ${DDNS_SCRIPT_TARGET} >> ${LOG_FILE} 2>&1"

    # 1. 先获取现有 crontab（如果没有 crontab，则输出空），并过滤掉已存在的同样命令行
    local tmp_cron="/tmp/cron_backup.$$"
    crontab -l 2>/dev/null | grep -v "${DDNS_SCRIPT_TARGET}" > "${tmp_cron}" || true

    # 2. 将新行追加到临时文件
    echo "${cron_line}" >> "${tmp_cron}"

    # 3. 重新安装 crontab
    crontab "${tmp_cron}"
    rm -f "${tmp_cron}"

    log "【信息】已将定时任务添加到 root 的 crontab："
    log "    ${cron_line}"
}

#############################
# ========= 主逻辑 =========
#############################

ensure_root

# 1. 安装 jq、wget
ensure_jq
ensure_wget

# 2. 优化 Linux 内核参数
log "【信息】开始优化 Linux 内核参数..."
cat <<'EOF' > /etc/sysctl.d/99-ec2-network-tweaks.conf
# 启用 BBR 拥塞控制算法
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 增加 TCP 连接数限制
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

# 让 sysctl 修改立即生效
sysctl --system

log "【信息】Linux 内核网络优化完成。"

# 3. 调整文件描述符和 systemd 限制
log "【信息】开始调整文件描述符和 systemd 资源限制..."
cat <<'EOF' >> /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

cat <<'EOF' >> /etc/systemd/system.conf
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

cat <<'EOF' >> /etc/systemd/user.conf
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

# 让 systemd 设置生效
systemctl daemon-reexec

log "【信息】文件描述符和 systemd 限制调整完成。"

# 4. 配置系统时区为 Asia/Shanghai
log "【信息】开始配置系统时区为 Asia/Shanghai..."
if [[ -f /usr/share/zoneinfo/Asia/Shanghai ]]; then
    timedatectl set-timezone Asia/Shanghai
    log "【信息】系统时区已成功设置为 Asia/Shanghai。"
else
    log "【错误】找不到 /usr/share/zoneinfo/Asia/Shanghai，请确认 tzdata 是否已安装。"
fi

# 5. 下载并执行原有的 install.sh
log "【信息】开始下载并执行 install.sh 脚本..."
TMP_INSTALL_SH="/tmp/install_ec2.sh"
wget -O "${TMP_INSTALL_SH}" --no-check-certificate "${INSTALL_SH_URL}" || {
    log "【错误】下载 install.sh 脚本失败。"
    exit 1
}
chmod +x "${TMP_INSTALL_SH}"
bash "${TMP_INSTALL_SH}" || {
    log "【错误】执行 install.sh 脚本失败，请检查脚本内容。"
    rm -f "${TMP_INSTALL_SH}"
    exit 1
}
rm -f "${TMP_INSTALL_SH}"
log "【信息】install.sh 脚本执行完成。"

# 6. 将 ddns_update.sh 从 GitHub 拉取到 /usr/local/bin 并赋可执行权限
log "【信息】开始从 GitHub 拉取 ddns_update.sh 并部署..."
wget -O "${DDNS_SCRIPT_TARGET}" --no-check-certificate "${DDNS_RAW_URL}" || {
    log "【错误】从 ${DDNS_RAW_URL} 拉取 ddns_update.sh 失败。"
    exit 1
}
chmod +x "${DDNS_SCRIPT_TARGET}"
log "【信息】ddns_update.sh 已部署到 ${DDNS_SCRIPT_TARGET} 并赋予可执行权限。"

# 7. 本次立即执行一次 ddns_update.sh
log "【信息】本次立即执行 ddns_update.sh，同步当前 IP 到 DDNS..."
bash "${DDNS_SCRIPT_TARGET}" || log "【错误】ddns_update.sh 执行失败，请检查 /var/log/cloudflare_ddns.log"

# 8. 自动将 ddns_update.sh 加入 root 的 crontab
log "【信息】开始将定时任务写入 root 的 crontab..."
create_cron_entry

log "【信息】所有步骤完成！"
log "以后系统将每 1 分钟自动运行 ddns_update.sh，并把日志写到 ${LOG_FILE}"
