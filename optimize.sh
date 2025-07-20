#!/usr/bin/env bash

# 输出颜色定义
CSI="\033["
CEND="${CSI}0m"
CRED="${CSI}1;31m"
CYELLOW="${CSI}1;33m"
CCYAN="${CSI}1;36m"

OUT_ALERT() { echo -e "${CYELLOW}[警告] $1${CEND}"; }
OUT_ERROR() { echo -e "${CRED}[错误] $1${CEND}"; }
OUT_INFO() { echo -e "${CCYAN}[信息] $1${CEND}"; }

# 获取系统信息
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
        centos | rhel) release="centos" ;;
        debian | ubuntu) release="$ID" ;;
        *)
            OUT_ERROR "不支持的操作系统！"
            exit 1
            ;;
        esac
        os_version="$VERSION_ID"
    else
        OUT_ERROR "无法检测操作系统版本！"
        exit 1
    fi
}

set_timezone() { timedatectl set-timezone Asia/Shanghai; }

get_ip_info() {
    local country=$(curl -s --max-time 5 http://ip-api.com/line/?fields=country)
    [[ "$country" == "China" ]] && echo "China" && return
    ping6 -c1 -w5 2606:4700:4700::1111 &>/dev/null && echo "IPv6" || echo "Other"
}

set_dns() {
    chattr -i /etc/resolv.conf &>/dev/null
    rm -rf /etc/resolv.conf

    case "$1" in
    China) dns_servers="223.5.5.5 223.6.6.6" ;;
    IPv6) dns_servers="1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888" ;;
    *) dns_servers="1.1.1.1 8.8.8.8" ;;
    esac

    for dns in $dns_servers; do echo "nameserver $dns"; done >/etc/resolv.conf

    sed -i '/dns-nameservers\|dns-search/d' /etc/network/interfaces /etc/network/interfaces.d/50-cloud-init &>/dev/null

    chattr +i /etc/resolv.conf &>/dev/null
    OUT_INFO "DNS修改完成"
}

check_dhcp() {
    local iface=$(ip route show default | awk '/default/ {print $5}')

    if ! grep -i "dhcp" /etc/network/interfaces 2>/dev/null | grep -q "$iface" &&
        ! [[ -f "/run/systemd/netif/leases/$iface" ]] &&
        ! [[ -f "/var/lib/dhcp/dhclient.$iface.leases" ]]; then
        return
    fi

    if [[ -f "/etc/dhcp/dhclient.conf" ]]; then
        sed -i '/supersede domain-name-servers/d' /etc/dhcp/dhclient.conf
        local dns_servers_comma=$(echo $dns_servers | tr ' ' ',')
        echo "supersede domain-name-servers $dns_servers_comma;" >>/etc/dhcp/dhclient.conf
    fi
}

# configure_firewall() {
#     local default_ip=$(curl -s --max-time 5 http://ip-api.com/line/?fields=query)
#     local ssh_port=$(ss -tnlp | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u)
#     ssh_port=${ssh_port:-22}

#     command -v iptables &>/dev/null || { [[ "$release" == "centos" ]] && yum install -y iptables || apt-get install -y iptables; }

#     iptables -F && iptables -X && iptables -Z

#     cat >/etc/rc.local <<EOF
# #!/bin/bash
# iptables -A INPUT -d "$default_ip" -p tcp --syn --dport 1:$((ssh_port - 1)) -j DROP
# iptables -A INPUT -d "$default_ip" -p tcp --syn --dport $((ssh_port + 1)):65535 -j DROP
# exit 0
# EOF
#     chmod +x /etc/rc.local
#     systemctl daemon-reload
#     systemctl restart rc-local

#     OUT_INFO "防火墙配置完成"
# }

# 生成软件源列表
generate_sources_list() {
    local ip_info="$1"
    local new_sources_list
    # 检测CPU架构
    CPU_ARCH=$(uname -m)

    if [[ "$release" == "debian" ]] && [[ "$os_version" == "12" ]]; then
        if [[ "$ip_info" == "China" ]] || [[ "$ip_info" == "CN" ]]; then
            new_sources_list=$(
                cat <<EOF
deb https://mirrors.tencent.com/debian/ bookworm main non-free non-free-firmware contrib
deb-src https://mirrors.tencent.com/debian/ bookworm main non-free non-free-firmware contrib
deb https://mirrors.tencent.com/debian-security/ bookworm-security main
deb-src https://mirrors.tencent.com/debian-security/ bookworm-security main
deb https://mirrors.tencent.com/debian/ bookworm-updates main non-free non-free-firmware contrib
deb-src https://mirrors.tencent.com/debian/ bookworm-updates main non-free non-free-firmware contrib
deb https://mirrors.tencent.com/debian/ bookworm-backports main non-free non-free-firmware contrib
deb-src https://mirrors.tencent.com/debian/ bookworm-backports main non-free non-free-firmware contrib
EOF
            )
        else
            new_sources_list=$(
                cat <<EOF
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security/ bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security/ bookworm-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ bookworm-backports main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-backports main contrib non-free non-free-firmware
EOF
            )
        fi
    elif [[ "$release" == "debian" ]] && [[ "$os_version" == "11" ]]; then
        if [[ "$ip_info" == "China" ]] || [[ "$ip_info" == "CN" ]]; then
            new_sources_list=$(
                cat <<EOF
deb http://mirrors.tencent.com/debian bullseye main contrib non-free
deb http://mirrors.tencent.com/debian bullseye-updates main contrib non-free
deb http://mirrors.tencent.com/debian bullseye-backports main contrib non-free
EOF
            )
        else
            new_sources_list=$(
                cat <<EOF
deb http://deb.debian.org/debian/ bullseye main contrib non-free
deb-src http://deb.debian.org/debian/ bullseye main contrib non-free

deb http://security.debian.org/debian-security bullseye-security main contrib non-free
deb-src http://security.debian.org/debian-security bullseye-security main contrib non-free

deb http://deb.debian.org/debian/ bullseye-updates main contrib non-free
deb-src http://deb.debian.org/debian/ bullseye-updates main contrib non-free

deb http://deb.debian.org/debian/ bullseye-backports main contrib non-free
deb-src http://deb.debian.org/debian/ bullseye-backports main contrib non-free
EOF
            )
        fi
    elif [[ "$release" == "debian" ]] && [[ "$os_version" == "10" ]]; then
        if [[ "$ip_info" == "China" ]] || [[ "$ip_info" == "CN" ]]; then
            new_sources_list=$(
                cat <<EOF
deb http://mirrors.tencent.com/debian buster main contrib non-free
deb http://mirrors.tencent.com/debian buster-updates main contrib non-free
deb http://mirrors.tencent.com/debian buster-backports main contrib non-free
EOF
            )
        else
            new_sources_list=$(
                cat <<EOF
deb http://deb.debian.org/debian buster main contrib non-free
deb-src http://deb.debian.org/debian buster main contrib non-free
deb http://security.debian.org/debian-security buster/updates main contrib non-free
deb-src http://security.debian.org/debian-security buster/updates main contrib non-free
deb http://deb.debian.org/debian buster-updates main contrib non-free
deb-src http://deb.debian.org/debian buster-updates main contrib non-free
EOF
            )
        fi
    elif [[ "$release" == "ubuntu" ]]; then
        if [[ "$ip_info" == "China" ]] || [[ "$ip_info" == "CN" ]]; then
            # 对于位于中国的服务器，使用阿里云镜像，不区分架构
            new_sources_list=$(
                cat <<EOF
## 阿里云Ubuntu镜像源
deb http://mirrors.aliyun.com/ubuntu/ focal main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-security main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-proposed main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-backports main restricted universe multiverse
EOF
            )
        elif [[ "$CPU_ARCH" == "aarch64" ]]; then
            # 对于ARM架构的服务器（不在中国），使用Ubuntu的ports存储库
            new_sources_list=$(
                cat <<EOF
deb http://ports.ubuntu.com/ubuntu-ports/ focal main restricted
deb http://ports.ubuntu.com/ubuntu-ports/ focal-updates main restricted
deb http://ports.ubuntu.com/ubuntu-ports/ focal universe
deb http://ports.ubuntu.com/ubuntu-ports/ focal-updates universe
deb http://ports.ubuntu.com/ubuntu-ports/ focal multiverse
deb http://ports.ubuntu.com/ubuntu-ports/ focal-updates multiverse
deb http://ports.ubuntu.com/ubuntu-ports/ focal-backports main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports/ focal-security main restricted
deb http://ports.ubuntu.com/ubuntu-ports/ focal-security universe
deb http://ports.ubuntu.com/ubuntu-ports/ focal-security multiverse
EOF
            )
        else
            # 对于不在中国并且不是ARM架构的服务器，使用默认的Ubuntu镜像源
            new_sources_list=$(
                cat <<EOF
## 默认的Ubuntu镜像源
deb http://archive.ubuntu.com/ubuntu/ focal main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ focal-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ focal-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ focal-backports main restricted universe multiverse
EOF
            )
        fi
    fi

    # 写入 sources.list
    echo "$new_sources_list" >/etc/apt/sources.list
    OUT_INFO "已更新软件源列表。"
}

# 更新和安装必要的软件包
update_system() {
    if [[ "$release" == "centos" ]]; then
        yum makecache
        yum install epel-release -y
        yum update -y
        yum install sudo nload htop mtr iperf3 -y
    else
        apt-get update -y

        # 检查是否安装 sniproxy 并且已启动，如果已安装且已启动，则锁定 sniproxy 更新
        if systemctl is-active sniproxy &>/dev/null; then
            apt-mark hold sniproxy &>/dev/null
        fi
        # 设置为非交互模式，避免弹出配置文件更新窗口
        export DEBIAN_FRONTEND=noninteractive

        # 自动保留本地配置文件
        apt-get upgrade -y -o Dpkg::Options::="--force-confold"

        apt-get autoremove --purge -y
        apt-get install sudo nload htop mtr iperf3 lsb-release dnsutils net-tools -y
    fi

    sudo systemctl mask systemd-networkd-wait-online.service

    # 判断是否安装了宝塔面板
    if [[ ! -d "/www/server/panel" ]]; then
        # 禁用并卸载不需要的服务
        local services_to_disable=("ufw")
        for service in "${services_to_disable[@]}"; do
            if systemctl is-enabled "$service" &>/dev/null; then
                systemctl stop "$service"
                systemctl disable "$service"
                if [[ "$release" != "centos" ]]; then
                    apt-get remove --purge "$service" -y
                fi
                OUT_INFO "已禁用并卸载服务：$service"
            fi
        done
    fi

    OUT_INFO "系统更新和软件包安装完成。"
}

# 优化系统配置
optimize_system() {
    # 备份原始配置文件
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
    cp /etc/security/limits.conf /etc/security/limits.conf.bak

    # 优化 sysctl.conf
    cat >/etc/sysctl.conf <<EOF
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

EOF

    # 优化 limits.conf
    cat >/etc/security/limits.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
EOF

    sysctl -p
    echo "" >/var/log/wtmp

    OUT_INFO "系统优化完成，建议重启系统以应用所有更改。"
}

main() {
    get_os_info
    set_timezone

    [[ "$1" == "cn" ]] && {
        ip_info="China"
        forced_cn=true
    } || {
        ip_info=$(get_ip_info)
        forced_cn=false
    }

    set_dns "$ip_info"
    check_dhcp
    generate_sources_list "$ip_info"
    update_system
    optimize_system

    # if [[ "$ip_info" == "China" && "$forced_cn" == false ]]; then
    #     iface=$(ip route show default | awk '/default/{print $5}')
    #     [[ $(ip -4 addr show dev "$iface" | grep inet | wc -l) -gt 1 ]] && configure_firewall
    # fi
}

main "$1"
