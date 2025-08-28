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
#   7. 自动将 ddns_update.sh 加入 root 的 crontab（按 CRON_SCHEDULE 执行），并把日志写到 /var/log/cloudflare_ddns.log
#
# 使用方法：
#   chmod +x setup_ec2.sh
#   sudo ./setup_ec2.sh
#
# （说明：仅增加 cron 安装/可用性保障，不改你的其他逻辑）

set -euo pipefail

#############################
# ======= 配置区域 =======
#############################

# 1. ddns_update.sh 在 GitHub 上的 Raw 地址（保持你的原值不变）
DDNS_RAW_URL="https://raw.githubusercontent.com/dmdmdmxy/ddns/refs/heads/main/pass-hk01-DNS.sh"

# 2. 下载后放置的目标路径：
DDNS_SCRIPT_TARGET="/usr/local/bin/ddns_update.sh"

# 3. 原 install.sh 脚本下载地址（保持原先逻辑不变）：
INSTALL_SH_URL="http://ytpass.fxscloud.com:666/client/AKS0E00LBr4J5rXj/install.sh"

# 4. 定时任务表达式（保持你的原值：每 1 分钟执行一次）
CRON_SCHEDULE="*/1 * * * *"

# 5. 日志文件路径（ddns 更新脚本会将日志写入此文件）
LOG_FILE="/var/log/cloudflare_ddns.log"

#############################
# ======== 函数区 =========
#############################

log() {
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

# ========= 新增：确保 cron 可用 =========
# 安装并启动 cron/crond，返回 crontab 的绝对路径
ensure_cron_ready() {
    if [[ -f /etc/debian_version ]]; then
        if ! command -v crontab &>/dev/null; then
            apt-get update -y && apt-get install -y cron
        fi
        systemctl enable --now cron 2>/dev/null || true
    elif [[ -f /etc/redhat-release ]]; then
        (yum install -y cronie || dnf install -y cronie) || true
        systemctl enable --now crond 2>/dev/null || true
    elif command -v apk >/dev/null 2>&1; then
        if ! command -v crontab &>/dev/null; then
            apk add --no-cache cronie
        fi
        rc-update add crond default || true
        rc-service crond start || true
    fi

    # 定位 crontab 可执行文件
    local bin
    bin="$(command -v crontab || true)"
    if [[ -z "$bin" ]]; then
        for p in /usr/bin/crontab /bin/crontab /usr/sbin/crontab; do
            [[ -x "$p" ]] && bin="$p" && break
        done
    fi

    if [[ -z "$bin" ]]; then
        echo "【错误】仍未找到 crontab，请手动安装 cron/cronie 后重试。"
        exit 1
    fi

    echo "$bin"
}

# ——替换你脚本里的 create_cron_entry()——
create_cron_entry() {
  # 确保已安装并能用
  ensure_cron_ready

  local CRON_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  local cron_line="${CRON_SCHEDULE} /usr/bin/env -i PATH=${CRON_PATH} /bin/bash \"${DDNS_SCRIPT_TARGET}\" >> \"${LOG_FILE}\" 2>&1"
  local SCRIPT_PATH
  SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  # 读取当前 crontab，过滤旧任务，再把新行追加，然后整体喂给 crontab -
  {
    crontab -l 2>/dev/null \
      | grep -F -v "${DDNS_SCRIPT_TARGET}" \
      | grep -F -v "${SCRIPT_PATH}" \
      | grep -v "install.sh" \
      || true
    echo "${cron_line}"
  } | crontab -

  log "【信息】已将定时任务添加到 root 的 crontab："
  log "    ${cron_line}"
}

#############################
# ========= 主逻辑 =========
#############################

ensure_root

# 准备日志文件
touch "${LOG_FILE}" && chmod 644 "${LOG_FILE}"

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
if command -v timedatectl &>/dev/null; then
    timedatectl set-timezone Asia/Shanghai
    log "【信息】系统时区已成功设置为 Asia/Shanghai。"
elif [[ -f /usr/share/zoneinfo/Asia/Shanghai ]]; then
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
    log "【信息】系统时区已通过软链方式设置为 Asia/Shanghai。"
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
bash "${DDNS_SCRIPT_TARGET}" || log "【错误】ddns_update.sh 执行失败，请检查 ${LOG_FILE}"

# 8. 自动将 ddns_update.sh 加入 root 的 crontab（在函数内部会确保 cron 已安装）
log "【信息】开始将定时任务写入 root 的 crontab..."
create_cron_entry

log "【信息】所有步骤完成！"
log "以后系统将按调度表达式运行：${CRON_SCHEDULE}；日志写入：${LOG_FILE}"
