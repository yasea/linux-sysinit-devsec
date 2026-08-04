#!/usr/bin/env bash
################################################################################
#   Author      : 0x5c0f (Enhanced with Dev-Sec Baseline & Anti-Lockout)
#   Date        : 2026-08-04
#   Version     : 2.1.0-PROD
#   Description : Linux Server Fast Init, Performance & Dev-Sec Security Hardening
#   Usage       : bash ./sysinit.sh
#   Environment :
#       AUTO_FIREWALL=yes   非交互防火墙（默认推荐规则）
#       AUTO_SSH=yes        非交互SSH加固（默认推荐规则）
#       HOSTNAME=myhost     自定义主机名（默认随机生成）
#       TZ=Asia/Shanghai    时区（默认上海）
#       SSH_PORT=22         SSH端口（默认22）
################################################################################

set -euo pipefail

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# ==============================================================================
# 0. 全局常量与环境检测
# ==============================================================================
declare -- LOG_LEVEL="INFO"
declare -- __SUDO__=""
declare -- __INSTALL_CMD__=""
declare -- SERVER_TYPE=""
declare -- __OS_VERSION_ID__=""
declare -- __OS_VERSION__=""
declare -- __OS_ARCH__=""
declare -- __INIT_SYSTEM__=""
declare -- __LOG_FILE__=""
declare -- __TMP_FILES__=""

declare -- SOURCEDIR="/data/softsrc"
declare -- SOFTDIR="/data/software"

# 配置区 - 可通过环境变量覆盖
: "${AUTO_FIREWALL:=}"
: "${AUTO_SSH:=}"
: "${HOSTNAME:=}"
: "${TZ:=Asia/Shanghai}"
: "${SSH_PORT:=22}"
: "${BACKUP_DIR:=/var/backups/sysinit}"
: "${LOG_DIR:=/var/log}"

# ==============================================================================
# 0.0 错误处理与清理 trap
# ==============================================================================
__CLEANUP_TMP__() {
    if [ -n "${__TMP_FILES__}" ]; then
        for f in ${__TMP_FILES__}; do
            rm -f "${f}" 2>/dev/null || true
        done
    fi
}

__ERR_HANDLER__() {
    local exit_code=$?
    __SAY__ ERROR "脚本执行异常退出 (code=${exit_code})，错误发生在: ${1:-未知位置}"
    __SAY__ ERROR "执行日志已保存至: ${__LOG_FILE__}"
    __SAY__ ERROR "配置备份目录: ${BACKUP_DIR}"
    __CLEANUP_TMP__
}

trap '__ERR_HANDLER__ "${BASH_COMMAND}"' ERR

# ==============================================================================
# 0.1 统一彩色输出日志函数（同步写入文件日志）
# ==============================================================================
__SAY__() {
    local -r ENDCOLOR="\033[0m"
    local -r INFOCOLOR="\033[1;34m"
    local -r SUCCESSCOLOR="\033[0;32m"
    local -r ERRORCOLOR="\033[0;31m"
    local -r WARNCOLOR="\033[0;33m"
    local -r DEBUGCOLOR="\033[0;35m"

    local LOGTYPE="INFOCOLOR"
    local msg_level="INFO"

    case "$1" in
        [Dd][Ee][Bb][Uu][Gg])  msg_level="DEBUG";   LOGTYPE="DEBUGCOLOR";   shift ;;
        [Ii][Nn][Ff][Oo])      msg_level="INFO";     LOGTYPE="INFOCOLOR";   shift ;;
        [Ss][Uu][Cc][Cc][Ee][Ss][Ss]) msg_level="SUCCESS"; LOGTYPE="SUCCESSCOLOR"; shift ;;
        [Ww][Aa][Rr][Nn])      msg_level="WARN";     LOGTYPE="WARNCOLOR";   shift ;;
        [Ee][Rr][Rr][Oo][Rr])   msg_level="ERROR";    LOGTYPE="ERRORCOLOR";  shift ;;
    esac

    local current_priority=1 msg_priority=1
    case "${LOG_LEVEL}" in
        [Ii][Nn][Ff][Oo]|[Ss][Uu][Cc][Cc][Ee][Ss][Ss]) current_priority=1 ;;
        [Ww][Aa][Rr][Nn]) current_priority=2 ;;
        [Ee][Rr][Rr][Oo][Rr]) current_priority=3 ;;
        [Dd][Ee][Bb][Uu][Gg]) current_priority=4 ;;
    esac
    case "${msg_level}" in
        INFO|SUCCESS) msg_priority=1 ;;
        WARN) msg_priority=2 ;;
        ERROR) msg_priority=3 ;;
        DEBUG) msg_priority=4 ;;
    esac

    [ "${msg_priority}" -gt "${current_priority}" ] && return 0

    local log_line
    log_line="[$(date '+%Y-%m-%d_%H:%M:%S')] [${msg_level}] ${*}"

    # 控制台彩色输出
    printf "[%s] [%b%s%b] %s%b\n" \
        "$(date '+%Y-%m-%d_%H:%M:%S')" \
        "${!LOGTYPE}" "${msg_level}" "${ENDCOLOR}" \
        "${*}" "${ENDCOLOR}"

    # 文件日志（无颜色，需 root 写入 /var/log）
    if [ -n "${__LOG_FILE__}" ] && [ -w "$(dirname "${__LOG_FILE__}")" ]; then
        echo "${log_line}" >> "${__LOG_FILE__}" 2>/dev/null || true
    elif [ -n "${__LOG_FILE__}" ] && [ -n "${__SUDO__}" ]; then
        echo "${log_line}" | ${__SUDO__} tee -a "${__LOG_FILE__}" >/dev/null 2>/dev/null || true
    fi
}

# ==============================================================================
# 0.2 统一备份函数
# ==============================================================================
__BACKUP__() {
    local src="$1"
    local backup_root="${BACKUP_DIR}"
    ${__SUDO__} mkdir -p "${backup_root}" 2>/dev/null || true
    local dest="${backup_root}/$(basename "${src}").$(date +%Y%m%d-%H%M%S)"
    if [ -f "${src}" ]; then
        if ${__SUDO__} cp -p "${src}" "${dest}" 2>/dev/null; then
            __SAY__ DEBUG "备份 ${src} -> ${dest}"
        else
            __SAY__ WARN "备份失败: ${src}"
        fi
    fi
}

# ==============================================================================
# 0.3 临时文件注册（退出时自动清理）
# ==============================================================================
__REG_TMP__() {
    __TMP_FILES__="${__TMP_FILES__} $1"
}

# ==============================================================================
# 0.3 交互确认函数
# ==============================================================================
__CONFIRM__() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    # 非 TTY 环境，使用默认值
    if [ ! -t 0 ]; then
        if [ "${default}" = "y" ]; then
            return 0
        else
            return 1
        fi
    fi

    while true; do
        if [ "${default}" = "y" ]; then
            printf "  >>> %s [Y/n]: " "${prompt}"
        elif [ "${default}" = "n" ]; then
            printf "  >>> %s [y/N]: " "${prompt}"
        else
            printf "  >>> %s [y/n]: " "${prompt}"
        fi
        read -r answer
        answer="${answer:-${default}}"
        case "${answer}" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) printf "  请输入 y 或 n\n" ;;
        esac
    done
}

# ==============================================================================
# 0.4 交互输入函数
# ==============================================================================
__PROMPT__() {
    local prompt="$1"
    local default="${2:-}"
    local input

    # 非 TTY 环境，返回默认值
    if [ ! -t 0 ]; then
        echo "${default}"
        return 0
    fi

    if [ -n "${default}" ]; then
        printf "  >>> %s [%s]: " "${prompt}" "${default}"
    else
        printf "  >>> %s: " "${prompt}"
    fi
    read -r input
    echo "${input:-${default}}"
}

# ==============================================================================
# 0.5 工具存在性检测
# ==============================================================================
UTILS__CMD_EXISTS__() {
    command -v "$1" >/dev/null 2>&1
}

UTILS__DETECT_SUDO__() {
    if [ -z "${__SUDO__}" ]; then
        if [ "$(id -u)" -ne 0 ]; then
            if UTILS__CMD_EXISTS__ sudo; then
                __SUDO__="sudo"
                __SAY__ WARN "非 root 用户，自动切换为 sudo 模式执行"
            else
                __SAY__ ERROR "需要 root 权限执行此脚本，未找到 sudo，中止"
                exit 1
            fi
        else
            __SUDO__=""
        fi
    fi
}

# ==============================================================================
# 0.6 操作系统检测（增强兼容性）
# ==============================================================================
UTILS__DETECT_OS__() {
    __SAY__ INFO "检测操作系统信息..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        __OS_VERSION_ID__="${ID}"
        __OS_VERSION__="${VERSION_ID:-0}"
        # 使用 ID_LIKE 辅助判断衍生版
        local id_like="${ID_LIKE:-}"
        case "${__OS_VERSION_ID__}" in
            debian|ubuntu|centos|rocky|almalinux|amzn|alinux|openEuler|fedora|rhel)
                : ;;  # 已支持
            *)
                # 通过 ID_LIKE 匹配
                if echo "${id_like}" | grep -qiE "debian|ubuntu"; then
                    __OS_VERSION_ID__="debian"
                elif echo "${id_like}" | grep -qiE "rhel|fedora|centos"; then
                    __OS_VERSION_ID__="centos"
                else
                    __SAY__ WARN "未完全支持的操作系统: ${__OS_VERSION_ID__} (ID_LIKE=${id_like})，尝试兼容模式"
                fi
                ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        __OS_VERSION_ID__="centos"
        __OS_VERSION__=$(grep -oE '[0-9]+\.[0-9]+' < /etc/redhat-release | head -1)
    else
        __SAY__ ERROR "无法识别当前操作系统类型（仅支持 Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux/Amazon Linux 等主流发行版）"
        exit 1
    fi
    __OS_ARCH__=$(uname -m)
    __SAY__ INFO "当前环境: ${__OS_VERSION_ID__} ${__OS_VERSION__} (${__OS_ARCH__})"
}

# ==============================================================================
# 0.7 包管理器检测（增强兼容性）
# ==============================================================================
UTILS__DETECT_PACKAGE_MANAGER__() {
    if [ -z "${__INSTALL_CMD__}" ]; then
        local managers=("apt-get" "dnf" "yum" "zypper" "apk" "pacman")
        for mgr in "${managers[@]}"; do
            if UTILS__CMD_EXISTS__ "${mgr}"; then
                __INSTALL_CMD__="${mgr}"
                break
            fi
        done
        if [ -z "${__INSTALL_CMD__}" ]; then
            __SAY__ ERROR "无法找到受支持的包管理器（支持 apt-get/dnf/yum/zypper/apk/pacman）"
            exit 1
        fi
    fi
    __SAY__ INFO "使用包管理器: ${__INSTALL_CMD__}"
}

# ==============================================================================
# 0.8 云环境检测（增强兼容性）
# ==============================================================================
UTILS__DETECT_CLOUD__() {
    if [ -n "${SERVER_TYPE}" ]; then
        return 0
    fi

    # 方法1: DMI/SMBIOS 检测
    if [ -f /sys/devices/virtual/dmi/id/product_name ]; then
        local product
        product=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "Unknown")
        case "${product}" in
            *Alibaba*|*Aliyun*)  SERVER_TYPE="cloud"; __SAY__ INFO "云环境: 阿里云" ;;
            *Amazon*|*EC2*)      SERVER_TYPE="cloud"; __SAY__ INFO "云环境: AWS EC2" ;;
            *Google*|*GCE*)      SERVER_TYPE="cloud"; __SAY__ INFO "云环境: Google Cloud" ;;
            *Tencent*|*CVM*)     SERVER_TYPE="cloud"; __SAY__ INFO "云环境: 腾讯云" ;;
            *Microsoft*|*Azure*) SERVER_TYPE="cloud"; __SAY__ INFO "云环境: Azure" ;;
            *Oracle*)            SERVER_TYPE="cloud"; __SAY__ INFO "云环境: Oracle Cloud" ;;
            *HVM*|*KVM*|*Virtual*) SERVER_TYPE="cloud" ;;  # 虚拟机，暂标记为 cloud
            *)                   SERVER_TYPE="local" ;;
        esac
    else
        SERVER_TYPE="local"
    fi

    # 方法2: 通过 metadata 服务二次确认（仅当未识别为 cloud 时）
    if [ "${SERVER_TYPE}" != "cloud" ]; then
        if UTILS__CMD_EXISTS__ curl; then
            local metadata_result
            metadata_result=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/ 2>/dev/null || true)
            if [ -n "${metadata_result}" ]; then
                SERVER_TYPE="cloud"
                __SAY__ INFO "云环境: 通过 metadata 服务确认"
            fi
        fi
    fi

    __SAY__ INFO "系统运行环境识别: ${SERVER_TYPE}"
}

# ==============================================================================
# 0.9 Init 系统检测
# ==============================================================================
UTILS__DETECT_INIT_SYSTEM__() {
    if [ -d /run/systemd/system ]; then
        __INIT_SYSTEM__="systemd"
    elif [ -f /sbin/init ] && strings /sbin/init 2>/dev/null | grep -qi "upstart"; then
        __INIT_SYSTEM__="upstart"
    elif [ -f /etc/init.d/rc ] || [ -d /etc/rc.d ]; then
        __INIT_SYSTEM__="sysvinit"
    else
        __INIT_SYSTEM__="unknown"
    fi
    __SAY__ INFO "初始化系统: ${__INIT_SYSTEM__}"
}

# ==============================================================================
# 0.10 工具存在性预检
# ==============================================================================
UTILS__PRECHECK_TOOLS__() {
    local required_tools=("sed" "tee" "grep" "date" "printf" "uname" "id")
    local missing=()
    for tool in "${required_tools[@]}"; do
        if ! UTILS__CMD_EXISTS__ "${tool}"; then
            missing+=("${tool}")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        __SAY__ ERROR "缺少必要系统工具: ${missing[*]}"
        exit 1
    fi
}

# ==============================================================================
# 0.11 初始化准备
# ==============================================================================
UTILS__DETECT_SUDO__
UTILS__PRECHECK_TOOLS__
UTILS__DETECT_OS__
UTILS__DETECT_PACKAGE_MANAGER__
UTILS__DETECT_CLOUD__
UTILS__DETECT_INIT_SYSTEM__

test ! -d "${SOURCEDIR}" && ${__SUDO__} mkdir -p "${SOURCEDIR}" || true
test ! -d "${SOFTDIR}" && ${__SUDO__} mkdir -p "${SOFTDIR}" || true


# ==============================================================================
# 1. 基础系统属性设置
# ==============================================================================
__PRECHECK__() {
    if [ -f "/opt/.server.init.executed" ]; then
        __SAY__ WARN "系统初始化标记已存在 (/opt/.server.init.executed)"
        if ! __CONFIRM__ "是否忽略标记继续执行？" "n"; then
            __SAY__ ERROR "如需重新执行，请删除 /opt/.server.init.executed 标记文件后重试。"
            exit 1
        fi
    fi
}

__SET_HOSTNAME__() {
    local hostname="${HOSTNAME}"
    if [ -z "${hostname}" ]; then
        hostname=$(tr -dc 'a-z0-9' < /dev/urandom | fold -w 8 | head -n 1)
    fi

    __SAY__ INFO "设置主机名: ${hostname}"
    if UTILS__CMD_EXISTS__ hostnamectl; then
        ${__SUDO__} hostnamectl set-hostname "${hostname}" 2>/dev/null || true
    else
        ${__SUDO__} hostname "${hostname}" 2>/dev/null || __SAY__ WARN "hostname 命令不可用"
        echo "${hostname}" | ${__SUDO__} tee /etc/hostname >/dev/null 2>&1
    fi

    # 同步 /etc/hosts
    __BACKUP__ /etc/hosts
    if grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        ${__SUDO__} sed -i "/127.0.1.1/d" /etc/hosts
    fi
    echo "127.0.1.1 ${hostname}" | ${__SUDO__} tee -a /etc/hosts >/dev/null
}

__SET_SOURCEREPO__() {
    __SAY__ INFO "检查系统镜像源配置..."
    if [ "${SERVER_TYPE}" == 'cloud' ]; then
        __SAY__ INFO "检测到云服务器环境，跳过系统源配置（保持厂商云内网加速默认源）"
        return 0
    fi
    __SAY__ WARN "本地或自建服务器环境，当前保持现有软件源不做覆写"
}


# ==============================================================================
# 2. 基础依赖包更新与安装
# ==============================================================================
__BASIC_INSTALL__() {
    __SAY__ INFO "开始同步包管理器缓存并安装常用系统调优工具..."

    # 包管理器缓存更新
    case "${__INSTALL_CMD__}" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive ${__SUDO__} ${__INSTALL_CMD__} update -y
            # 系统安全更新（用户确认）
            if __CONFIRM__ "是否执行全系统安全更新（apt upgrade）？" "n"; then
                DEBIAN_FRONTEND=noninteractive ${__SUDO__} ${__INSTALL_CMD__} upgrade -y
            else
                __SAY__ WARN "跳过系统安全更新，建议后续手动执行 apt upgrade"
            fi
            ;;
        yum|dnf)
            ${__SUDO__} ${__INSTALL_CMD__} makecache || true
            if __CONFIRM__ "是否执行全系统安全更新（${__INSTALL_CMD__} update）？" "n"; then
                ${__SUDO__} ${__INSTALL_CMD__} update -y
            else
                __SAY__ WARN "跳过系统安全更新，建议后续手动执行 ${__INSTALL_CMD__} update"
            fi
            ;;
        zypper)
            ${__SUDO__} ${__INSTALL_CMD__} refresh || true
            if __CONFIRM__ "是否执行全系统安全更新（zypper update）？" "n"; then
                ${__SUDO__} ${__INSTALL_CMD__} update -y
            fi
            ;;
        apk)
            ${__SUDO__} ${__INSTALL_CMD__} update || true
            if __CONFIRM__ "是否执行全系统安全更新（apk upgrade）？" "n"; then
                ${__SUDO__} ${__INSTALL_CMD__} upgrade || true
            fi
            ;;
        pacman)
            ${__SUDO__} ${__INSTALL_CMD__} -Sy || true
            if __CONFIRM__ "是否执行全系统安全更新（pacman -Su）？" "n"; then
                ${__SUDO__} ${__INSTALL_CMD__} -Su --noconfirm || true
            fi
            ;;
    esac

    # 安装常用工具
    case "${__INSTALL_CMD__}" in
        apt-get)
            local req_pkgs="build-essential dos2unix vim htop bash-completion make git wget curl netcat-openbsd tmux tree ca-certificates chrony sudo lsof"
            DEBIAN_FRONTEND=noninteractive ${__SUDO__} ${__INSTALL_CMD__} install -y "${req_pkgs}" || true

            # 修复 root 用户 LANG 缺失报错问题
            if [ -f "/root/.profile" ]; then
                __BACKUP__ /root/.profile
                if ! grep -q "LANG" /root/.profile 2>/dev/null; then
                    echo "export LANG=C.UTF-8" | ${__SUDO__} tee -a /root/.profile >/dev/null
                fi
            fi
            ;;
        yum|dnf)
            if [ ! -f "/etc/yum.repos.d/epel.repo" ]; then
                ${__SUDO__} ${__INSTALL_CMD__} install epel-release -y || true
            fi
            ${__SUDO__} ${__INSTALL_CMD__} groupinstall -y "Development tools" 2>/dev/null || \
                ${__SUDO__} ${__INSTALL_CMD__} install -y gcc gcc-c++ make || true

            local tools="tree dos2unix net-tools bash-completion wget vim make git tmux nmap-ncat chrony sudo lsof htop curl"
            ${__SUDO__} ${__INSTALL_CMD__} install -y ${tools} || true

            ${__SUDO__} chmod +x /etc/rc.d/rc.local 2>/dev/null || true
            ;;
        zypper)
            local suse_tools="patterns-devel-base-devel dos2unix vim htop bash-completion make git wget curl netcat-openbsd tmux tree ca-certificates chrony sudo lsof"
            ${__SUDO__} ${__INSTALL_CMD__} install -y ${suse_tools} || true
            ;;
        apk)
            local alpine_tools="build-base dos2unix vim htop bash-completion make git wget curl netcat-openbsd tmux tree ca-certificates chrony sudo lsof"
            ${__SUDO__} ${__INSTALL_CMD__} add ${alpine_tools} || true
            ;;
        pacman)
            local arch_tools="base-devel dos2unix vim htop bash-completion make git wget curl gnu-netcat tmux tree ca-certificates chrony sudo lsof"
            ${__SUDO__} ${__INSTALL_CMD__} -S --noconfirm ${arch_tools} || true
            ;;
    esac
    __SAY__ SUCCESS "系统基础调优及工具软件安装完毕"
}


# ==============================================================================
# 3. SELinux 与防火墙设置
# ==============================================================================
__SET_SELINUX__() {
    case "${__OS_VERSION_ID__}" in
        ubuntu|debian)
            __SAY__ INFO "Debian/Ubuntu 系统默认为 AppArmor/无 SELinux，跳过修改"
            ;;
        centos|rocky|almalinux|amzn|alinux|openEuler|fedora|rhel)
            if [ -f "/etc/selinux/config" ]; then
                __SAY__ INFO "调整 SELinux 为 Permissive 模式（防止强制拦截破坏业务）"
                __BACKUP__ /etc/selinux/config
                ${__SUDO__} sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
                ${__SUDO__} setenforce 0 2>/dev/null || true
            fi
            ;;
    esac
}

# ==============================================================================
# 3.1 交互式防火墙配置
# ==============================================================================
__SET_FIREWALLD__() {
    __SAY__ INFO "配置防火墙规则..."

    # 检测当前防火墙状态
    local fw_active=false
    if [ "${__INIT_SYSTEM__}" = "systemd" ]; then
        if systemctl is-active --quiet firewalld.service 2>/dev/null; then
            fw_active=true
            __SAY__ INFO "检测到 firewalld 正在运行"
        fi
        if systemctl is-active --quiet ufw.service 2>/dev/null; then
            fw_active=true
            __SAY__ INFO "检测到 ufw 正在运行"
        fi
    fi

    # 交互确认
    if [ -t 0 ] && [ "${AUTO_FIREWALL}" != "yes" ]; then
        echo ""
        __SAY__ INFO "========== 防火墙配置 =========="
        __SAY__ INFO "建议规则："
        echo "  1. 默认策略: DROP（拒绝所有入站流量）"
        echo "  2. 放行规则:"
        echo "     - 回环接口 (lo) 全部放行"
        echo "     - 已建立连接 (ESTABLISHED,RELATED) 放行"
        echo "     - SSH 端口 (${SSH_PORT}) 放行"
        echo "     - ICMP (ping) 有限速率放行"
        echo "  3. 可额外添加指定 IP 和端口的放行规则"
        echo ""

        if ! __CONFIRM__ "是否启用防火墙配置？" "y"; then
            __SAY__ WARN "用户跳过防火墙配置"
            return 0
        fi
    fi

    # 禁用现有防火墙服务
    if [ "${__INIT_SYSTEM__}" = "systemd" ]; then
        ${__SUDO__} systemctl disable --now firewalld.service 2>/dev/null || true
        ${__SUDO__} systemctl disable --now ufw.service 2>/dev/null || true
    fi

    # 安装 iptables
    case "${__INSTALL_CMD__}" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive ${__SUDO__} ${__INSTALL_CMD__} install -y iptables iptables-persistent || true
            ;;
        yum|dnf|zypper)
            ${__SUDO__} ${__INSTALL_CMD__} install -y iptables-services iptables || true
            ;;
        apk)
            ${__SUDO__} ${__INSTALL_CMD__} add iptables ip6tables || true
            ;;
        pacman)
            ${__SUDO__} ${__INSTALL_CMD__} -S --noconfirm iptables || true
            ;;
    esac

    # 构建防火墙规则
    local tmp_rules
    tmp_rules=$(mktemp) || { __SAY__ ERROR "无法创建临时文件"; return 1; }
    __REG_TMP__ "${tmp_rules}"

    cat > "${tmp_rules}" <<'EOF'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# 回环接口放行
-A INPUT -i lo -j ACCEPT

# 已建立连接放行
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ICMP 有限速率放行
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/second -j ACCEPT

# SSH 放行
EOF

    echo "-A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT" >> "${tmp_rules}"

    # 交互添加额外 IP:端口规则
    if [ -t 0 ] && [ "${AUTO_FIREWALL}" != "yes" ]; then
        while __CONFIRM__ "是否添加额外的 IP:端口放行规则？" "n"; do
            local extra_ip extra_port extra_proto
            extra_ip=$(__PROMPT__ "允许的源 IP（留空表示所有来源）" "")
            extra_port=$(__PROMPT__ "目标端口号" "")
            extra_proto=$(__PROMPT__ "协议 (tcp/udp)" "tcp")

            # 输入校验
            if [ -z "${extra_port}" ]; then
                __SAY__ WARN "端口号不能为空，跳过"
                continue
            fi
            if ! [[ "${extra_port}" =~ ^[0-9]+$ ]] || [ "${extra_port}" -lt 1 ] || [ "${extra_port}" -gt 65535 ]; then
                __SAY__ WARN "端口号无效 (1-65535): ${extra_port}，跳过"
                continue
            fi
            case "${extra_proto}" in
                tcp|udp) : ;;
                *) __SAY__ WARN "协议无效 (tcp/udp): ${extra_proto}，默认使用 tcp"; extra_proto="tcp" ;;
            esac

            if [ -n "${extra_ip}" ]; then
                echo "-A INPUT -p ${extra_proto} -s ${extra_ip} --dport ${extra_port} -j ACCEPT" >> "${tmp_rules}"
                __SAY__ INFO "添加规则: ${extra_proto} ${extra_ip}:${extra_port}"
            else
                echo "-A INPUT -p ${extra_proto} --dport ${extra_port} -j ACCEPT" >> "${tmp_rules}"
                __SAY__ INFO "添加规则: ${extra_proto} 0.0.0.0/0:${extra_port}"
            fi
        done
    fi

    # 写入日志和提交
    cat >> "${tmp_rules}" <<'EOF'
# 记录被拒绝的包（限速防刷）
-A INPUT -j LOG --log-prefix "FW-DROP: " --log-limit 5/minute
COMMIT
EOF

    # 应用规则
    ${__SUDO__} mkdir -p /etc/iptables
    if [ -f /etc/iptables/rules.v4 ]; then
        __BACKUP__ /etc/iptables/rules.v4
    fi
    ${__SUDO__} cp "${tmp_rules}" /etc/iptables/rules.v4
    ${__SUDO__} chmod 600 /etc/iptables/rules.v4

    # 加载规则
    if ! ${__SUDO__} iptables-restore < /etc/iptables/rules.v4 2>/dev/null; then
        __SAY__ ERROR "iptables 规则加载失败，请检查 /etc/iptables/rules.v4 语法"
        return 1
    fi

    # 持久化
    case "${__INSTALL_CMD__}" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive ${__SUDO__} ${__INSTALL_CMD__} install -y iptables-persistent 2>/dev/null || true
            ${__SUDO__} netfilter-persistent save 2>/dev/null || true
            ;;
        yum|dnf)
            if [ "${__INIT_SYSTEM__}" = "systemd" ]; then
                ${__SUDO__} systemctl enable iptables.service 2>/dev/null || true
            fi
            ${__SUDO__} service iptables save 2>/dev/null || true
            ;;
    esac

    __SAY__ SUCCESS "防火墙规则已应用（默认 DROP，SSH ${SSH_PORT} 已放行）"
}


# ==============================================================================
# 4. 核心优化：高并发性能调优 + Dev-Sec 内核安全基线
# ==============================================================================
__SET_KERN_OPTIMIZE__() {
    __SAY__ INFO "写入内网性能调优与 Dev-Sec 操作系统防护内核参数 (/etc/sysctl.d/99-zz-sysctl.conf)..."

    ${__SUDO__} tee /etc/sysctl.d/99-zz-sysctl.conf >/dev/null <<'EOF'
# --- [1] 高并发网络性能优化 (Performance Tuning) ---
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 32768
net.core.wmem_default = 8388608
net.core.rmem_default = 8388608
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_orphans = 3276800
net.ipv4.tcp_mem = 94500000 915000000 927000000
net.ipv4.ip_local_port_range = 1024 65535

# --- [2] 文件句柄与系统并发范围 ---
fs.file-max = 6815744
fs.inotify.max_user_watches = 524288
vm.max_map_count = 655360

# --- [3] Netfilter 连接跟踪提升 ---
net.nf_conntrack_max = 25000000
net.netfilter.nf_conntrack_max = 25000000
net.netfilter.nf_conntrack_tcp_timeout_established = 180
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120

# --- [4] Dev-Sec Security Baseline (安全基线加固) ---
# 防止 IP 欺骗，启用反向路径过滤
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# 禁用 ICMP 重定向报文接入，防止伪造路由
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# 禁用源路由选路
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# 开启异常与伪造 IP 数据包日志记录
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# 忽略广播 ICMP 报文和各种错误的 ICMP 错误提示
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 内存布局随机化 (ASLR) 防范缓冲区溢出，限制 dmesg 与内核指针可见性
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
EOF

    __SAY__ INFO "加载内核参数..."
    if ! ${__SUDO__} sysctl -p /etc/sysctl.d/99-zz-sysctl.conf >/dev/null 2>&1; then
        __SAY__ WARN "部分内核参数加载失败，请检查 /etc/sysctl.d/99-zz-sysctl.conf 中的参数是否在当前内核支持范围内"
    fi

    # 使用 limits.d 独立文件（幂等写入）
    __SAY__ INFO "配置系统文件句柄限制 (/etc/security/limits.d/99-sysinit.conf)..."
    ${__SUDO__} tee /etc/security/limits.d/99-sysinit.conf >/dev/null <<'EOF'
# Server Init - File and Process Limits Hardening
*      soft    nofile      65535
*      hard    nofile      65535
*      soft    nproc       65535
*      hard    nproc       65535
root   soft    nofile      65535
root   hard    nofile      65535
EOF
    ${__SUDO__} chmod 644 /etc/security/limits.d/99-sysinit.conf

    __SAY__ SUCCESS "高并发网络及安全内核调优加载生效"
}


# ==============================================================================
# 5. Dev-Sec Linux 操作系统基线安全检查与加固
# ==============================================================================
__SET_DEVSEC_OS_HARDEN__() {
    __SAY__ INFO "执行 Dev-Sec OS 基线专项安全加固..."

    # 1. 设置安全全局掩码
    __SAY__ INFO "配置默认安全掩码 (umask 027)..."
    __BACKUP__ /etc/profile
    if grep -q "umask" /etc/profile; then
        ${__SUDO__} sed -i 's/^umask.*/umask 027/' /etc/profile
    else
        echo "umask 027" | ${__SUDO__} tee -a /etc/profile >/dev/null
    fi
    if [ -f "/etc/login.defs" ]; then
        __BACKUP__ /etc/login.defs
        ${__SUDO__} sed -i 's/^UMASK.*/UMASK 027/' /etc/login.defs
    fi

    # 2. 口令安全策略强化
    if [ -f "/etc/login.defs" ]; then
        __SAY__ INFO "强化登录密码超时失效及过期策略 (/etc/login.defs)..."
        __BACKUP__ /etc/login.defs
        ${__SUDO__} sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 90/' /etc/login.defs
        ${__SUDO__} sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS 7/' /etc/login.defs
        ${__SUDO__} sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE 14/' /etc/login.defs
    fi

    # 3. 系统内置账户登录态收缩
    __SAY__ INFO "锁紧系统特殊服务账号交互式 shell..."
    for user in ftp games irc lp mail news uucp operator sync shutdown halt; do
        if id "${user}" >/dev/null 2>&1; then
            ${__SUDO__} usermod -s /usr/sbin/nologin "${user}" 2>/dev/null || \
            ${__SUDO__} usermod -s /sbin/nologin "${user}" 2>/dev/null || true
        fi
    done

    # 4. 关键凭证文件安全读写权限绑定
    __SAY__ INFO "修正 /etc/passwd 与 /etc/shadow 核心身份凭证只读保护控制..."
    ${__SUDO__} chmod 644 /etc/passwd /etc/group 2>/dev/null || true
    ${__SUDO__} chmod 400 /etc/shadow /etc/gshadow 2>/dev/null || true
    ${__SUDO__} chown root:root /etc/passwd /etc/shadow /etc/group /etc/gshadow 2>/dev/null || true

    # 5. /tmp 公共目录防越权清理位
    __SAY__ INFO "保障 /tmp 目录粘滞位启用..."
    ${__SUDO__} chmod 1777 /tmp /var/tmp 2>/dev/null || true

    __SAY__ SUCCESS "Dev-Sec OS 基线加固子任务执行完成"
}


# ==============================================================================
# 6. 系统时区与审计服务配置
# ==============================================================================
__SET_TIMEZONE__() {
    __SAY__ INFO "设置系统时区为 ${TZ}..."
    ${__SUDO__} ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime

    __SAY__ INFO "激活并自启 chrony 精确时钟同步..."
    if [ "${__INIT_SYSTEM__}" = "systemd" ]; then
        if systemctl list-unit-files 2>/dev/null | grep -q "chronyd.service"; then
            ${__SUDO__} systemctl enable --now chronyd.service 2>/dev/null || true
        elif systemctl list-unit-files 2>/dev/null | grep -q "chrony.service"; then
            ${__SUDO__} systemctl enable --now chrony.service 2>/dev/null || true
        fi
    fi
}

__SET_CMDAUDIT__() {
    __SAY__ INFO "配置安全命令日志审计记录 /var/log/cmdAudit..."
    local audit_dir="/var/log/cmdAudit"
    local today
    today=$(date '+%y-%m-%d')
    local audit_file="${audit_dir}/audit_${today}.log"

    ${__SUDO__} mkdir -p "${audit_dir}"
    if [ ! -f "${audit_file}" ]; then
        ${__SUDO__} touch "${audit_file}"
        ${__SUDO__} chmod 600 "${audit_file}"
        if UTILS__CMD_EXISTS__ chattr; then
            ${__SUDO__} chattr +a "${audit_file}" 2>/dev/null || true
        fi
    fi

    ${__SUDO__} tee /etc/profile.d/cmdAudit.sh >/dev/null <<'AUDITEOF'
COMMANDAUDIT_FILE="/var/log/cmdAudit/audit_$(date '+%y-%m-%d').log"

__AUDIT_INIT__() {
    local audit_dir="/var/log/cmdAudit"
    if [ ! -d "${audit_dir}" ]; then
        mkdir -p "${audit_dir}" 2>/dev/null
    fi
    if [ ! -f "${COMMANDAUDIT_FILE}" ]; then
        touch "${COMMANDAUDIT_FILE}" 2>/dev/null
        chmod 600 "${COMMANDAUDIT_FILE}" 2>/dev/null
        if command -v chattr >/dev/null 2>&1; then
            chattr +a "${COMMANDAUDIT_FILE}" 2>/dev/null || true
        fi
    fi
}

if [ "${1:-}" = "cron" ]; then
    __AUDIT_INIT__
    exit 0
fi

if [ $(id -u) -eq 0 ]; then
    __AUDIT_INIT__
fi

export HISTSIZE=1000
export HISTFILESIZE=1500
export HISTTIMEFORMAT="%Y%m%d-%H%M%S: "
export PROMPT_COMMAND='{ date "+%T ### [$(whoami)] ### $(who am i |awk "{print \$1\" \"\$2\" \"\$5}") ### $(pwd) ### $(history 1 | { read x cmd; echo "$cmd"; })"; } >> $COMMANDAUDIT_FILE 2>/dev/null'
AUDITEOF

    ${__SUDO__} chmod +x /etc/profile.d/cmdAudit.sh

    # 使用 cron.d 独立文件替代 /etc/crontab
    if [ ! -f /etc/cron.d/cmdAudit ]; then
        ${__SUDO__} tee /etc/cron.d/cmdAudit >/dev/null <<'CRONEOF'
0 0 * * * root /usr/bin/bash /etc/profile.d/cmdAudit.sh cron
@reboot root /usr/bin/bash /etc/profile.d/cmdAudit.sh cron
CRONEOF
        ${__SUDO__} chmod 644 /etc/cron.d/cmdAudit
    fi

    # 配置 logrotate
    ${__SUDO__} tee /etc/logrotate.d/cmdAudit >/dev/null <<'LOGROTEOF'
/var/log/cmdAudit/*.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 600 root root
    sharedscripts
    postrotate
        /usr/bin/find /var/log/cmdAudit/ -name "*.log" -mtime +90 -delete
    endscript
}
LOGROTEOF
    ${__SUDO__} chmod 644 /etc/logrotate.d/cmdAudit

    __SAY__ SUCCESS "命令审计日志已配置（权限 600，logrotate 已设置）"
}

__SET_DISABLE_SERVICES__() {
    __SAY__ INFO "关闭高风险与非必须的本地系统服务..."
    local services="postfix.service rpcbind.service rpcbind.socket exim4.service"
    for service in ${services}; do
        # 同时检查 active 和 enabled 状态
        if ${__SUDO__} systemctl is-active --quiet "${service}" 2>/dev/null; then
            __SAY__ INFO "停止服务 -> ${service}"
            ${__SUDO__} systemctl stop "${service}" 2>/dev/null || true
        fi
        if ${__SUDO__} systemctl is-enabled --quiet "${service}" 2>/dev/null; then
            __SAY__ INFO "禁用服务 -> ${service}"
            ${__SUDO__} systemctl disable "${service}" 2>/dev/null || true
        fi
    done
}


# ==============================================================================
# 7. Dev-Sec SSH 加固与"防锁死（Anti-Lockout）"配置引擎
# ==============================================================================
__SET_SSHD_CONFIG__() {
    local sshd_config="/etc/ssh/sshd_config"

    if [ "${SERVER_TYPE}" == "cloud" ]; then
        __SAY__ WARN "检测到云平台控制台默认镜像，SSH 原厂商默认存在安全连通策略配置，当前仅执行轻量补充"
    fi

    # 交互确认
    if [ -t 0 ] && [ "${AUTO_SSH}" != "yes" ]; then
        echo ""
        __SAY__ INFO "========== SSH 安全加固 =========="
        __SAY__ INFO "建议配置："
        echo "  1. 禁用 root 密码登录 (PermitRootLogin prohibit-password)"
        echo "  2. 禁用密码认证，启用密钥认证 (PasswordAuthentication no)"
        echo "  3. 禁用空密码 (PermitEmptyPasswords no)"
        echo "  4. 限制最大认证尝试次数 (MaxAuthTries 4)"
        echo "  5. 禁用 X11 转发 (X11Forwarding no)"
        echo "  6. 禁用 GSSAPI 认证 (GSSAPIAuthentication no)"
        echo "  7. 禁用 DNS 反向解析 (UseDNS no)"
        echo "  8. 客户端保活检测 (ClientAliveInterval 300, ClientAliveCountMax 3)"
        echo ""

        if ! __CONFIRM__ "是否应用 SSH 安全加固配置？" "y"; then
            __SAY__ WARN "用户跳过 SSH 加固配置"
            return 0
        fi
    fi

    # --- [Anti-Lockout 步骤 1: 强制时间戳备份] ---
    local backup_file="${sshd_config}.backup-$(date +%Y%m%d-%H%M%S)"
    __SAY__ INFO "开启 SSH 防锁死支持，正在保存当前正常会话的配置文件备份至 -> ${backup_file}"
    ${__SUDO__} cp -p "${sshd_config}" "${backup_file}"

    # --- [Dev-Sec SSH Baseline 参数更新] ---
    __SAY__ INFO "应用 SSHD 标准安全参数列表..."

    local -A ssh_params=(
        ["UseDNS"]="no"
        ["GSSAPIAuthentication"]="no"
        ["PermitEmptyPasswords"]="no"
        ["X11Forwarding"]="no"
        ["MaxAuthTries"]="4"
        ["ClientAliveInterval"]="300"
        ["ClientAliveCountMax"]="3"
        ["Protocol"]="2"
    )

    # 交互式 SSH 额外配置
    if [ -t 0 ] && [ "${AUTO_SSH}" != "yes" ]; then
        if __CONFIRM__ "是否禁用 root 密码登录（推荐）？" "y"; then
            ssh_params["PermitRootLogin"]="prohibit-password"
        fi
        if __CONFIRM__ "是否禁用密码认证，仅允许密钥登录（推荐）？" "y"; then
            ssh_params["PasswordAuthentication"]="no"
        fi
    else
        # 非交互模式默认推荐
        ssh_params["PermitRootLogin"]="prohibit-password"
        ssh_params["PasswordAuthentication"]="no"
    fi

    for param in "${!ssh_params[@]}"; do
        local value="${ssh_params[$param]}"
        if grep -q -E "^#?${param}" "${sshd_config}"; then
            ${__SUDO__} sed -i "s/^#\?${param}.*/${param} ${value}/" "${sshd_config}"
        else
            echo "${param} ${value}" | ${__SUDO__} tee -a "${sshd_config}" >/dev/null
        fi
    done

    # --- [Anti-Lockout 步骤 2: 语法合规性检查与安全重载] ---
    __SAY__ INFO "验证 SSHD 语法完整性 (sshd -t)..."
    if ${__SUDO__} sshd -t 2>/dev/null; then
        __SAY__ SUCCESS "SSH 语法校验合法！平滑重载服务（不中断现有已建立连接）..."
        if [ "${__INIT_SYSTEM__}" = "systemd" ]; then
            ${__SUDO__} systemctl reload sshd.service 2>/dev/null || \
                ${__SUDO__} systemctl reload ssh.service 2>/dev/null || \
                __SAY__ WARN "未找到 sshd reload 指令，需稍后手动执行 service ssh reload"
        else
            ${__SUDO__} service sshd reload 2>/dev/null || \
                ${__SUDO__} service ssh reload 2>/dev/null || \
                __SAY__ WARN "未找到 sshd reload 指令，需稍后手动执行"
        fi
    else
        # 触发重大语法错误，即刻回滚防止远程断网
        __SAY__ ERROR "SSH 配置语法校验异常！触发安全【防锁死回滚策略】，立刻还原旧版配置！"
        ${__SUDO__} cp -f "${backup_file}" "${sshd_config}"
        exit 1
    fi
}


# ==============================================================================
# 8. 执行主干与报告检查
# ==============================================================================
__MAIN__() {
    # 初始化执行日志
    __LOG_FILE__="${LOG_DIR}/sysinit-$(date +%Y%m%d-%H%M%S).log"
    ${__SUDO__} mkdir -p "${LOG_DIR}" 2>/dev/null || true
    ${__SUDO__} touch "${__LOG_FILE__}" 2>/dev/null || true
    ${__SUDO__} chmod 600 "${__LOG_FILE__}" 2>/dev/null || true

    __SAY__ INFO "============= 正在运行 Linux 服务器快速安全优化初始化脚本 ============="
    __SAY__ INFO "执行日志: ${__LOG_FILE__}"
    __SAY__ INFO "配置备份目录: ${BACKUP_DIR}"
    __PRECHECK__
    __SET_HOSTNAME__
    __SET_SOURCEREPO__
    __BASIC_INSTALL__
    __SET_SELINUX__
    __SET_FIREWALLD__
    __SET_KERN_OPTIMIZE__
    __SET_DEVSEC_OS_HARDEN__
    __SET_TIMEZONE__
    __SET_CMDAUDIT__
    __SET_DISABLE_SERVICES__
    __SET_SSHD_CONFIG__

    # 所有步骤成功后写入初始化标记
    ${__SUDO__} mkdir -p /opt
    ${__SUDO__} tee "/opt/.server.init.executed" >/dev/null <<EOF
sysinit $(date +%Y%m%d%H%M%S)
EOF

    __SAY__ SUCCESS "================ 优化结束！系统安全基线已全面加固 =================="
    __SAY__ INFO "执行日志已保存: ${__LOG_FILE__}"
    __SAY__ INFO "配置备份目录: ${BACKUP_DIR}"
    __SAY__ INFO "新内核参数配置与登录策略调整建议在适当时机重启服务器 (reboot) 后以取得最深度的优化支持。"

    __CLEANUP_TMP__
}

__MAIN__ "$@"
