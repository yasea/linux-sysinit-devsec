#!/usr/bin/env bash
################################################################################
#   Author      : 0x5c0f (Enhanced with Dev-Sec Baseline & Anti-Lockout)
#   Date        : 2026-08-14
#   Version     : 2.2.2-PROD
#   Description : Linux Server Fast Init, Performance & Dev-Sec Security Hardening
#   Usage       : bash ./sysinit.sh
#   Environment :
#       AUTO_FIREWALL=yes   非交互防火墙（默认推荐规则）
#       AUTO_SSH=yes        非交互SSH加固（默认推荐规则）
#       HOSTNAME=myhost     自定义主机名（默认随机生成）
#       TZ=Asia/Shanghai    时区（默认上海）
#       SSH_PORT=22         SSH端口（默认22）
#       SSH_ALLOW_IPS=      SSH放行源IP（逗号分隔，留空=放行所有并告警）
#       AUTO_WHITELIST_CURRENT_IP=yes  非交互且 AUTO_FIREWALL=yes 时自动将当前连接IP加入SSH白名单（默认yes）
#       ENABLE_SWAP=yes     创建 4G swapfile（默认 no）
#       SWAP_SIZE=4G        swap 大小（默认 4G）
#       ENABLE_FAIL2BAN=yes 安装并配置 fail2ban sshd jail（默认 no）
#       DISABLE_IPV6=yes    关闭 IPv6（默认 no）
#       ENABLE_JOURNALD=yes 配置 journald 持久化（默认 no）
#       ENABLE_UNATTENDED=yes 启用 unattended-upgrades 安全自动更新（默认 no）
#       ENABLE_SYSSTAT=yes  安装 sysstat/sar 系统活动采集（默认 no）
#       CREATE_DATA_DIRS=yes 创建 /data 业务目录结构（默认 no）
################################################################################

set -euo pipefail

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# bash 版本检查（依赖关联数组 local -A，需 bash >= 4）
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "错误: 本脚本需要 bash >= 4（当前 ${BASH_VERSION}）" >&2
    exit 1
fi

# 用法帮助
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'USAGE'
用法: bash sysinit.sh [--help]

一键完成 Linux 服务器初始化与 Dev-Sec 安全基线加固。

常用环境变量:
  AUTO_FIREWALL=yes        非交互防火墙（默认推荐规则）
  AUTO_SSH=yes             非交互 SSH 加固（默认推荐配置）
  HOSTNAME=myhost          自定义主机名（默认随机）
  SSH_PORT=22              SSH 端口（防火墙放行此端口）
  SSH_ALLOW_IPS=           SSH 放行源 IP（逗号分隔；留空=自动白名单当前 IP 或全放+告警）
  AUTO_WHITELIST_CURRENT_IP=yes  非交互且 AUTO_FIREWALL=yes 时自动放行当前连接 IP
  TZ=Asia/Shanghai         时区
  ENABLE_SWAP=yes / ENABLE_FAIL2BAN=yes / DISABLE_IPV6=yes / ENABLE_JOURNALD=yes
  ENABLE_UNATTENDED=yes / ENABLE_SYSSTAT=yes / CREATE_DATA_DIRS=yes
  BACKUP_DIR=/var/backups/sysinit   LOG_DIR=/var/log   LOG_LEVEL=INFO

示例:
  AUTO_FIREWALL=yes AUTO_SSH=yes bash sysinit.sh
USAGE
    exit 0
fi

# ==============================================================================
# 0. 全局常量与环境检测
# ==============================================================================
: "${LOG_LEVEL:=INFO}"
declare -- __SUDO__=""
declare -- __INSTALL_CMD__=""
declare -- SERVER_TYPE=""
declare -- __OS_VERSION_ID__=""
declare -- __OS_VERSION__=""
declare -- __OS_ARCH__=""
declare -- __INIT_SYSTEM__=""
declare -- __LOG_FILE__=""
declare -- __TMP_FILES__=""
declare -- __INSTALL_FAILED_PKGS__=""

declare -- SOURCEDIR="/data/softsrc"
declare -- SOFTDIR="/data/software"

# 配置区 - 可通过环境变量覆盖
: "${AUTO_FIREWALL:=}"
: "${AUTO_SSH:=}"
: "${HOSTNAME:=}"
: "${TZ:=Asia/Shanghai}"
: "${SSH_PORT:=22}"
: "${SSH_ALLOW_IPS:=}"
: "${AUTO_WHITELIST_CURRENT_IP:=yes}"
: "${BACKUP_DIR:=/var/backups/sysinit}"
: "${LOG_DIR:=/var/log}"
: "${ENABLE_SWAP:=no}"
: "${SWAP_SIZE:=4G}"
: "${ENABLE_FAIL2BAN:=no}"
: "${DISABLE_IPV6:=no}"
: "${ENABLE_JOURNALD:=no}"
: "${ENABLE_UNATTENDED:=no}"
: "${ENABLE_SYSSTAT:=no}"
: "${CREATE_DATA_DIRS:=no}"

# 标记 yes/no 环境变量
__ENV_YES__() { [[ "${1}" =~ ^[Yy][Ee][Ss]$ ]]; }

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
    if [ -n "${__INSTALL_FAILED_PKGS__}" ]; then
        __SAY__ ERROR "以下包安装失败，需手工补装: ${__INSTALL_FAILED_PKGS__}"
    fi
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

    # LOG_LEVEL 表示“至少显示该级别及以上严重度”：DEBUG(0) < INFO/SUCCESS(1) < WARN(2) < ERROR(3)
    local threshold=1 msg_severity=1
    case "${LOG_LEVEL}" in
        [Dd][Ee][Bb][Uu][Gg]) threshold=0 ;;
        [Ww][Aa][Rr][Nn])     threshold=2 ;;
        [Ee][Rr][Rr][Oo][Rr]) threshold=3 ;;
        *)                    threshold=1 ;;
    esac
    case "${msg_level}" in
        DEBUG)        msg_severity=0 ;;
        INFO|SUCCESS) msg_severity=1 ;;
        WARN)         msg_severity=2 ;;
        ERROR)        msg_severity=3 ;;
    esac

    [ "${msg_severity}" -lt "${threshold}" ] && return 0

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
    local dest="${backup_root}/$(basename "${src}").$(date +%Y%m%d-%H%M%S-%N)"
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
            *HVM*)               SERVER_TYPE="cloud" ;;  # Xen HVM（AWS 等云）
            *KVM*|*Virtual*|*VMware*|*VirtualBox*) SERVER_TYPE="vm"; __SAY__ INFO "虚拟机环境: 本地虚拟化" ;;
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
    local required_tools=("sed" "tee" "grep" "awk" "date" "printf" "uname" "id")
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
# 0.11 包安装函数（逐个安装，统计失败）
# ==============================================================================
# 批量安装包（用数组展开为独立参数，避免 v2.1.0 的“引号包裹整串拆包失败”坑）
# 先整批安装（快）；失败时逐个回退定位失败包并记入 __INSTALL_FAILED_PKGS__，不静默吞掉
__INSTALL_PACKAGES__() {
    local pkgs=("$@")
    local failed=() cmd=()
    case "${__INSTALL_CMD__}" in
        apk)    cmd=(add) ;;
        pacman) cmd=(-S --noconfirm) ;;
        *)      cmd=(install -y) ;;
    esac

    if ! DEBIAN_FRONTEND=noninteractive ${__SUDO__} "${__INSTALL_CMD__}" "${cmd[@]}" "${pkgs[@]}" >/dev/null 2>&1; then
        for pkg in "${pkgs[@]}"; do
            if DEBIAN_FRONTEND=noninteractive ${__SUDO__} "${__INSTALL_CMD__}" "${cmd[@]}" "${pkg}" >/dev/null 2>&1; then
                __SAY__ DEBUG "已安装: ${pkg}"
            else
                failed+=("${pkg}")
                __SAY__ WARN "安装失败: ${pkg}"
            fi
        done
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        __INSTALL_FAILED_PKGS__="${__INSTALL_FAILED_PKGS__} ${failed[*]}"
        __SAY__ WARN "本轮失败包（稍后汇总）: ${failed[*]}"
    fi
}

# ==============================================================================
# 0.12 初始化准备
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
        # 首字符限定字母，避免生成以数字开头的不合法主机名
        hostname="$(tr -dc 'a-z' < /dev/urandom | head -c 1)$(tr -dc 'a-z0-9' < /dev/urandom | fold -w 7 | head -n 1)"
    fi

    __SAY__ INFO "设置主机名: ${hostname}"
    if UTILS__CMD_EXISTS__ hostnamectl; then
        ${__SUDO__} hostnamectl set-hostname "${hostname}" 2>/dev/null || true
    else
        ${__SUDO__} hostname "${hostname}" 2>/dev/null || __SAY__ WARN "hostname 命令不可用"
        echo "${hostname}" | ${__SUDO__} tee /etc/hostname >/dev/null 2>&1
    fi

    # 同步 /etc/hosts（容器/只读 /etc 下 sed -i 可能 EBUSY，降级为告警而非中止）
    __BACKUP__ /etc/hosts
    if grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        if ! ${__SUDO__} sed -i "/127.0.1.1/d" /etc/hosts 2>/dev/null; then
            __SAY__ WARN "清理 /etc/hosts 旧 127.0.1.1 条目失败（/etc/hosts 可能只读或为挂载文件），跳过"
        fi
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
            if ! DEBIAN_FRONTEND=noninteractive ${__SUDO__} ${__INSTALL_CMD__} update -y; then
                __SAY__ WARN "apt-get update 失败（可能网络/源异常），继续使用现有缓存"
            fi
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

    # 安装常用工具（v2.2.0 修复：逐包安装，不再用引号包裹整串导致拆包失败）
    case "${__INSTALL_CMD__}" in
        apt-get)
            local req_pkgs=(build-essential dos2unix vim htop bash-completion make git wget curl netcat-openbsd tmux tree ca-certificates chrony sudo lsof iproute2)
            __INSTALL_PACKAGES__ "${req_pkgs[@]}"

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

            local tools=(tree dos2unix net-tools bash-completion wget vim make git tmux nmap-ncat chrony sudo lsof htop curl)
            __INSTALL_PACKAGES__ "${tools[@]}"

            ${__SUDO__} chmod +x /etc/rc.d/rc.local 2>/dev/null || true
            ;;
        zypper)
            local suse_tools=(patterns-devel-base-devel dos2unix vim htop bash-completion make git wget curl netcat-openbsd tmux tree ca-certificates chrony sudo lsof)
            __INSTALL_PACKAGES__ "${suse_tools[@]}"
            ;;
        apk)
            local alpine_tools=(build-base dos2unix vim htop bash-completion make git wget curl netcat-openbsd tmux tree ca-certificates chrony sudo lsof)
            __INSTALL_PACKAGES__ "${alpine_tools[@]}"
            ;;
        pacman)
            local arch_tools=(base-devel dos2unix vim htop bash-completion make git wget curl gnu-netcat tmux tree ca-certificates chrony sudo lsof)
            __INSTALL_PACKAGES__ "${arch_tools[@]}"
            ;;
    esac

    # 可选：sysstat/sar 系统活动采集
    if __ENV_YES__ "${ENABLE_SYSSTAT}"; then
        __SAY__ INFO "安装 sysstat/sar 系统活动采集..."
        case "${__INSTALL_CMD__}" in
            apt-get) __INSTALL_PACKAGES__ sysstat
                     # 启用 sar 数据采集
                     ${__SUDO__} sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
                     ${__SUDO__} systemctl enable --now sysstat 2>/dev/null || true
                     ;;
            yum|dnf) __INSTALL_PACKAGES__ sysstat
                     ${__SUDO__} systemctl enable --now sysstat 2>/dev/null || true
                     ;;
        esac
    fi

    # 可选：unattended-upgrades 自动安全更新
    if __ENV_YES__ "${ENABLE_UNATTENDED}"; then
        __SAY__ INFO "配置 unattended-upgrades 自动安全更新..."
        case "${__INSTALL_CMD__}" in
            apt-get)
                __INSTALL_PACKAGES__ unattended-upgrades apt-listchanges
                ${__SUDO__} systemctl enable --now unattended-upgrades 2>/dev/null || true
                ${__SUDO__} systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
                ;;
        esac
    fi

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
# 3.1 防火墙配置 - ufw（唯一后端）
# ==============================================================================
# 探测当前 SSH 会话来源 IP（$SSH_CONNECTION 优先，其次 ss 推断）
# 输出：单个 IPv4 地址；未连接 SSH（如本机执行）则输出空
__GET_CURRENT_IP__() {
    local ip=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        ip=$(printf '%s\n' "${SSH_CONNECTION}" | awk '{print $1}')
    fi
    # 校验为合法 IPv4，否则尝试从活动 SSH 会话推断
    if ! printf '%s' "${ip}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        ip=""
        if UTILS__CMD_EXISTS__ ss; then
            # ss -tn state established 输出列: $3=本地 addr:port, $4=对端 addr:port
            # 匹配本地端口为 SSH_PORT 的已建立连接，取对端 IPv4
            ip=$(ss -tn state established 2>/dev/null | \
                 awk -v p=":${SSH_PORT}$" 'NR>1 && $3 ~ p {
                     split($4, a, ":"); c=a[1]
                     if (c ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print c; exit }
                 }')
        fi
    fi
    printf '%s\n' "${ip}"
}

# 关闭 ufw 的 IPv6 规则（/etc/default/ufw IPV6=no）
__DISABLE_UFW_IPV6__() {
    if [ -f /etc/default/ufw ]; then
        ${__SUDO__} sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
    fi
}

__SET_UFW__() {
    __SAY__ INFO "配置防火墙规则（ufw）..."

    # 交互确认
    if [ -t 0 ] && [ "${AUTO_FIREWALL}" != "yes" ]; then
        echo ""
        __SAY__ INFO "========== 防火墙配置 =========="
        __SAY__ INFO "建议规则："
        echo "  1. 默认策略: deny（拒绝所有入站流量）"
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

    # 确保已安装 ufw
    DEBIAN_FRONTEND=noninteractive ${__SUDO__} ${__INSTALL_CMD__} install -y ufw >/dev/null 2>&1 || true

    # 关闭 IPv6 规则（若 DISABLE_IPV6）
    if __ENV_YES__ "${DISABLE_IPV6}"; then
        __DISABLE_UFW_IPV6__
    fi

    # 每次执行都重置并重建（保证幂等，避免旧规则叠加）
    # ufw reset 会清空规则并恢复默认 allow 策略（不会锁死），随后脚本重建 deny 策略与规则
    __SAY__ INFO "重置 ufw 规则（保证幂等，重建干净规则集）..."
    ${__SUDO__} ufw --force reset >/dev/null 2>&1 || true

    # 默认策略
    ${__SUDO__} ufw default deny incoming
    ${__SUDO__} ufw default allow outgoing

    # 交互询问：是否自动将当前连接 IP 加入白名单
    local auto_whitelist="no"
    if [ -t 0 ] && [ "${AUTO_FIREWALL}" != "yes" ]; then
        if __CONFIRM__ "是否自动将当前连接的 IP 加入白名单（防止误锁）？" "y"; then
            auto_whitelist="yes"
        fi
    elif [ "${AUTO_FIREWALL}" = "yes" ] && __ENV_YES__ "${AUTO_WHITELIST_CURRENT_IP}"; then
        auto_whitelist="yes"
    fi

    local current_ip=""
    if [ "${auto_whitelist}" = "yes" ]; then
        current_ip=$(__GET_CURRENT_IP__)
        if [ -n "${current_ip}" ]; then
            __SAY__ INFO "自动放行当前连接 IP: ${current_ip}（SSH 端口 ${SSH_PORT}）"
            ${__SUDO__} ufw allow from "${current_ip}" to any port "${SSH_PORT}" proto tcp
        else
            __SAY__ WARN "未检测到当前连接 IP（可能本机直连），跳过自动白名单"
        fi
    fi

    # SSH 放行（限源或全放）
    if [ -n "${SSH_ALLOW_IPS}" ]; then
        local IFS_BAK="${IFS}"
        IFS=','
        for ip in ${SSH_ALLOW_IPS}; do
            ip=${ip//[[:space:]]/}  # 去空格
            [ -n "${ip}" ] && ${__SUDO__} ufw allow from "${ip}" to any port "${SSH_PORT}" proto tcp
        done
        IFS="${IFS_BAK}"
    elif [ "${auto_whitelist}" = "yes" ] && [ -n "${current_ip}" ]; then
        # 已放行当前 IP，不再全放开 SSH
        __SAY__ INFO "已通过白名单放行当前 IP (${current_ip})，SSH 不再对全来源开放"
    else
        __SAY__ WARN "SSH_ALLOW_IPS 未设置，SSH 放行所有来源（云安全组应限源兜底）"
        ${__SUDO__} ufw allow "${SSH_PORT}"/tcp
    fi

    # 交互添加额外 IP:端口规则
    if [ -t 0 ] && [ "${AUTO_FIREWALL}" != "yes" ]; then
        while __CONFIRM__ "是否添加额外的 IP:端口放行规则？" "n"; do
            local extra_ip extra_port extra_proto
            extra_ip=$(__PROMPT__ "允许的源 IP（留空表示所有来源）" "")
            extra_port=$(__PROMPT__ "目标端口号" "")
            extra_proto=$(__PROMPT__ "协议 (tcp/udp)" "tcp")

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
                ${__SUDO__} ufw allow from "${extra_ip}" to any port "${extra_port}" proto "${extra_proto}"
                __SAY__ INFO "添加规则: ${extra_proto} ${extra_ip}:${extra_port}"
            else
                ${__SUDO__} ufw allow "${extra_port}"/"${extra_proto}"
                __SAY__ INFO "添加规则: ${extra_proto} 0.0.0.0/0:${extra_port}"
            fi
        done
    fi

    # 禁用可能冲突的 netfilter-persistent / firewalld
    ${__SUDO__} systemctl disable --now netfilter-persistent 2>/dev/null || true
    ${__SUDO__} systemctl disable --now firewalld 2>/dev/null || true

    # 启用 ufw
    if ! ${__SUDO__} ufw --force enable; then
        __SAY__ ERROR "ufw 启用失败（可能需要 NET_ADMIN 权限或 iptables/nftables 支持），请手工排查"
        exit 1
    fi
    ${__SUDO__} systemctl enable ufw 2>/dev/null || true

    __SAY__ SUCCESS "ufw 防火墙已启用（默认 deny incoming，SSH ${SSH_PORT} 已放行）"
    __SAY__ INFO "查看规则: ufw status verbose"
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
net.ipv4.ip_local_port_range = 1024 65535

# --- [2] 文件句柄与系统并发范围 ---
fs.file-max = 6815744
fs.inotify.max_user_watches = 524288
vm.max_map_count = 655360

# --- [3] Netfilter 连接跟踪提升（需 nf_conntrack 模块）---
# nf_conntrack_max 在下方按内存动态计算后追加（避免小内存机器被 25M 条目拖垮）
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

    # v2.2.0 修复：先加载 nf_conntrack 模块再 sysctl，避免 nf_conntrack_* 参数失败
    ${__SUDO__} modprobe nf_conntrack 2>/dev/null || true

    # nf_conntrack_max 按内存动态计算（约 16KB 内存/条，夹在 65536~1048576 之间）
    local mem_kb conntrack_max
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    conntrack_max=$(( mem_kb / 16 ))
    [ "${conntrack_max}" -lt 65536 ] && conntrack_max=65536
    [ "${conntrack_max}" -gt 1048576 ] && conntrack_max=1048576
    {
        echo "net.nf_conntrack_max = ${conntrack_max}"
        echo "net.netfilter.nf_conntrack_max = ${conntrack_max}"
    } | ${__SUDO__} tee -a /etc/sysctl.d/99-zz-sysctl.conf >/dev/null

    __SAY__ INFO "加载内核参数..."
    # v2.2.0 修复：用 -e 忽略未知 key（如某些环境无 nf_conntrack），但仍报告其他错误
    if ! ${__SUDO__} sysctl -e -p /etc/sysctl.d/99-zz-sysctl.conf >/dev/null 2>&1; then
        __SAY__ WARN "部分内核参数加载失败（可能是当前内核不支持），请检查 /etc/sysctl.d/99-zz-sysctl.conf"
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
    # v2.2.0 改进：umask 改 022（云服务器多用户/容器场景，027 会导致容器挂载文件 403）
    # 同时设 USERGROUPS_ENAB no（否则 Ubuntu pam_umask 仍按组机制算出 0027）
    __SAY__ INFO "配置默认安全掩码 (umask 022)..."
    __BACKUP__ /etc/profile
    if grep -q "^umask" /etc/profile; then
        ${__SUDO__} sed -i 's/^umask.*/umask 022/' /etc/profile
    else
        echo "umask 022" | ${__SUDO__} tee -a /etc/profile >/dev/null
    fi
    if [ -f "/etc/login.defs" ]; then
        __BACKUP__ /etc/login.defs
        ${__SUDO__} sed -i 's/^UMASK.*/UMASK 022/' /etc/login.defs
        # USERGROUPS_ENAB no：禁用"用户私有组"机制，避免 umask 被补成 027
        if grep -q "^USERGROUPS_ENAB" /etc/login.defs; then
            ${__SUDO__} sed -i 's/^USERGROUPS_ENAB.*/USERGROUPS_ENAB no/' /etc/login.defs
        else
            echo "USERGROUPS_ENAB no" | ${__SUDO__} tee -a /etc/login.defs >/dev/null
        fi
    fi

    # 2. 口令安全策略强化（复用上方已备份的 /etc/login.defs）
    if [ -f "/etc/login.defs" ]; then
        __SAY__ INFO "强化登录密码超时失效及过期策略 (/etc/login.defs)..."
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

    # 云环境优化 NTP 源（按云厂商映射内网 NTP，非已知厂商保持默认 pool）
    if [ "${SERVER_TYPE}" = "cloud" ] && [ -f /etc/chrony/chrony.conf ]; then
        local ntp_server="" product=""
        product=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
        case "${product}" in
            *Alibaba*|*Aliyun*) ntp_server="ntp.aliyun.com" ;;
            *Amazon*|*EC2*)     ntp_server="169.254.169.123" ;;
            *Google*|*GCE*)     ntp_server="metadata.google.internal" ;;
            *Tencent*|*CVM*)    ntp_server="ntp.tencent.com" ;;
        esac
        if [ -n "${ntp_server}" ]; then
            __SAY__ INFO "检测到云环境，优化 chrony NTP 源 (${ntp_server})..."
            __BACKUP__ /etc/chrony/chrony.conf
            if ! grep -q "${ntp_server}" /etc/chrony/chrony.conf 2>/dev/null; then
                ${__SUDO__} sed -i "1i server ${ntp_server} iburst" /etc/chrony/chrony.conf
            fi
            ${__SUDO__} systemctl restart chronyd.service 2>/dev/null || \
            ${__SUDO__} systemctl restart chrony.service 2>/dev/null || true
        else
            __SAY__ INFO "云环境未识别具体厂商，保持默认 chrony NTP 源"
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
        # v2.2.0 修复：权限改 666（非 root 用户 PROMPT_COMMAND 也要写）
        # 保留 chattr +a 防篡改（只追加不可删改），但放开所有用户追加写
        ${__SUDO__} chmod 666 "${audit_file}"
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
        # v2.2.0: 666 让非 root 用户也能写，chattr +a 防篡改
        chmod 666 "${COMMANDAUDIT_FILE}" 2>/dev/null
        if command -v chattr >/dev/null 2>&1; then
            chattr +a "${COMMANDAUDIT_FILE}" 2>/dev/null || true
        fi
    fi
}

if [ "${1:-}" = "cron" ]; then
    __AUDIT_INIT__
    exit 0
fi

# 所有用户都初始化（非仅 root），因为审计文件现在 666
__AUDIT_INIT__

export HISTSIZE=1000
export HISTFILESIZE=1500
export HISTTIMEFORMAT="%Y%m%d-%H%M%S: "
export PROMPT_COMMAND='{ date "+%T ### [$(whoami)] ### $(who am i |awk "{print \$1\" \"\$2\" \"\$5}") ### $(pwd) ### $(history 1 | { read x cmd; echo "$cmd"; })"; } >> $COMMANDAUDIT_FILE 2>/dev/null'
AUDITEOF

    ${__SUDO__} chmod +x /etc/profile.d/cmdAudit.sh

    # v2.2.0 修复：审计目录设 sticky + others wx（用户可创建/追加自己的日志但不能列出他人文件）
    ${__SUDO__} chmod 1733 "${audit_dir}" 2>/dev/null || true

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
    create 666 root root
    sharedscripts
    postrotate
        /usr/bin/find /var/log/cmdAudit/ -name "*.log" -mtime +90 -delete
        if command -v chattr >/dev/null 2>&1; then chattr +a /var/log/cmdAudit/*.log 2>/dev/null || true; fi
    endscript
}
LOGROTEOF
    ${__SUDO__} chmod 644 /etc/logrotate.d/cmdAudit

    __SAY__ SUCCESS "命令审计日志已配置（权限 666+chattr +a，logrotate 已设置）"
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
        echo "  9. 登录宽限期 (LoginGraceTime 60)"
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
        ["LoginGraceTime"]="60"
        ["ClientAliveInterval"]="300"
        ["ClientAliveCountMax"]="3"
    )

    # v2.2.0 新增：DISABLE_IPV6 时设 AddressFamily inet
    if __ENV_YES__ "${DISABLE_IPV6}"; then
        ssh_params["AddressFamily"]="inet"
    fi

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

    # v2.2.0 新增：修正 sshd_config.d/*.conf 中的 PasswordAuthentication yes 覆盖
    # 坑：sshd "首值生效"机制，cloud-init drop-in 先于主配置读取 → 主配置改了无效
    if [ -d /etc/ssh/sshd_config.d ]; then
        __SAY__ INFO "检查 sshd_config.d/*.conf 中的密码认证覆盖..."
        local dropin
        for dropin in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "${dropin}" ] || continue
            if grep -qiE "^\s*PasswordAuthentication\s+yes" "${dropin}" 2>/dev/null; then
                __BACKUP__ "${dropin}"
                ${__SUDO__} sed -i 's/^\(\s*PasswordAuthentication\s*\)yes/\1no/I' "${dropin}"
                __SAY__ INFO "已修正 ${dropin} 中的 PasswordAuthentication yes -> no"
            fi
        done
    fi

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
# 7.1 可选：关闭 IPv6
# ==============================================================================
__SET_DISABLE_IPV6__() {
    if ! __ENV_YES__ "${DISABLE_IPV6}"; then
        return 0
    fi
    __SAY__ INFO "关闭 IPv6..."

    ${__SUDO__} tee /etc/sysctl.d/99-disable-ipv6.conf >/dev/null <<'EOF'
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    ${__SUDO__} sysctl -e -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true

    # ufw 关闭 IPv6 规则
    __DISABLE_UFW_IPV6__

    # nginx 去 [::] 监听（若已装）
    if [ -f /etc/nginx/sites-enabled/default ]; then
        __BACKUP__ /etc/nginx/sites-enabled/default
        ${__SUDO__} sed -i 's/^\(\s*listen \[::\]:.*\)/#\1/' /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi

    __SAY__ SUCCESS "IPv6 已关闭（sysctl + ufw IPV6=no + sshd AddressFamily inet 已在 SSH 模块设置）"
}


# ==============================================================================
# 7.2 可选：swap 配置
# ==============================================================================
__SET_SWAP__() {
    if ! __ENV_YES__ "${ENABLE_SWAP}"; then
        return 0
    fi
    __SAY__ INFO "配置 ${SWAP_SIZE} swapfile..."

    local swapfile="/swapfile"
    # 已存在则跳过
    if ${__SUDO__} swapon --show 2>/dev/null | grep -q "${swapfile}"; then
        __SAY__ INFO "swap ${swapfile} 已存在，跳过"
        return 0
    fi

    ${__SUDO__} fallocate -l "${SWAP_SIZE}" "${swapfile}" 2>/dev/null || {
        # fallocate 不支持时用 dd（bs=1M，count 为 MiB 数）
        __SAY__ INFO "fallocate 失败，使用 dd..."
        local swap_mib
        swap_mib=$(numfmt --from=iec "${SWAP_SIZE}" 2>/dev/null || echo 4096)
        swap_mib=$(( swap_mib / 1024 / 1024 ))
        [ "${swap_mib}" -lt 1 ] && swap_mib=4096
        ${__SUDO__} dd if=/dev/zero of="${swapfile}" bs=1M count="${swap_mib}" status=progress
    }
    ${__SUDO__} chmod 600 "${swapfile}"
    ${__SUDO__} mkswap "${swapfile}"
    ${__SUDO__} swapon "${swapfile}"

    # fstab 持久化
    if ! grep -q "${swapfile}" /etc/fstab 2>/dev/null; then
        echo "${swapfile} none swap sw 0 0" | ${__SUDO__} tee -a /etc/fstab >/dev/null
    fi

    __SAY__ SUCCESS "swap ${SWAP_SIZE} 已配置并启用（fstab 持久化）"
}


# ==============================================================================
# 7.3 可选：fail2ban
# ==============================================================================
__SET_FAIL2BAN__() {
    if ! __ENV_YES__ "${ENABLE_FAIL2BAN}"; then
        return 0
    fi
    __SAY__ INFO "安装并配置 fail2ban..."

    case "${__INSTALL_CMD__}" in
        apt-get) __INSTALL_PACKAGES__ fail2ban ;;
        yum|dnf) __INSTALL_PACKAGES__ fail2ban ;;
        *) __SAY__ WARN "fail2ban 在当前系统包管理器下可能不可用，跳过"; return 0 ;;
    esac

    # sshd jail 本地配置（jail.local 覆盖默认）
    ${__SUDO__} tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = %(sshd_log)s
backend = __FAIL2BAN_BACKEND__
maxretry = 5
findtime = 600
bantime = 3600
EOF
    # 替换占位符（jail.local 不支持变量，需实际值）
    ${__SUDO__} sed -i "s/\${SSH_PORT}/${SSH_PORT}/" /etc/fail2ban/jail.local 2>/dev/null || true
    local fb_backend="auto"
    [ "${__INIT_SYSTEM__}" = "systemd" ] && fb_backend="systemd"
    ${__SUDO__} sed -i "s/__FAIL2BAN_BACKEND__/${fb_backend}/" /etc/fail2ban/jail.local 2>/dev/null || true

    ${__SUDO__} systemctl enable --now fail2ban 2>/dev/null || true

    __SAY__ SUCCESS "fail2ban 已启用（sshd jail: maxretry=5 bantime=1h）"
}


# ==============================================================================
# 7.4 可选：journald 持久化
# ==============================================================================
__SET_JOURNALD__() {
    if ! __ENV_YES__ "${ENABLE_JOURNALD}"; then
        return 0
    fi
    __SAY__ INFO "配置 journald 持久化..."

    ${__SUDO__} mkdir -p /etc/systemd/journald.conf.d
    ${__SUDO__} tee /etc/systemd/journald.conf.d/sysinit.conf >/dev/null <<'EOF'
# sysinit journald 持久化配置
Storage=persistent
SystemMaxUse=256M
MaxRetentionSec=30day
EOF

    # 创建持久化目录
    ${__SUDO__} mkdir -p /var/log/journal
    ${__SUDO__} systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true

    ${__SUDO__} systemctl restart systemd-journald 2>/dev/null || true

    __SAY__ SUCCESS "journald 持久化已配置（256M/30天）"
}


# ==============================================================================
# 7.5 可选：创建 /data 业务目录结构
# ==============================================================================
__SET_DATA_DIRS__() {
    if ! __ENV_YES__ "${CREATE_DATA_DIRS}"; then
        return 0
    fi
    __SAY__ INFO "创建 /data 业务目录结构..."

    ${__SUDO__} mkdir -p /data/apps /data/scripts /data/backups /data/nginx-sites /data/creds
    # /data 根 0755
    ${__SUDO__} chmod 0755 /data
    # creds 目录 755（nginx 需读 htpasswd 等文件，文件自身 600）
    ${__SUDO__} chmod 0755 /data/creds
    # 其余子目录默认 755
    ${__SUDO__} chmod 0755 /data/apps /data/scripts /data/backups /data/nginx-sites

    __SAY__ SUCCESS "/data 业务目录已创建（apps/scripts/backups/nginx-sites/creds）"
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
    __SAY__ INFO "可选模块: SWAP=${ENABLE_SWAP} FAIL2BAN=${ENABLE_FAIL2BAN} IPV6_OFF=${DISABLE_IPV6} JOURNALD=${ENABLE_JOURNALD} UNATTENDED=${ENABLE_UNATTENDED} SYSSTAT=${ENABLE_SYSSTAT} DATA_DIRS=${CREATE_DATA_DIRS}"
    __PRECHECK__
    __SET_HOSTNAME__
    __SET_SOURCEREPO__
    __BASIC_INSTALL__
    __SET_SELINUX__
    __SET_UFW__
    __SET_KERN_OPTIMIZE__
    __SET_DEVSEC_OS_HARDEN__
    __SET_TIMEZONE__
    __SET_CMDAUDIT__
    __SET_DISABLE_SERVICES__
    __SET_SSHD_CONFIG__
    __SET_DISABLE_IPV6__
    __SET_SWAP__
    __SET_FAIL2BAN__
    __SET_JOURNALD__
    __SET_DATA_DIRS__

    # 所有步骤成功后写入初始化标记
    ${__SUDO__} mkdir -p /opt
    ${__SUDO__} tee "/opt/.server.init.executed" >/dev/null <<EOF
sysinit $(date +%Y%m%d%H%M%S)
EOF

    __SAY__ SUCCESS "================ 优化结束！系统安全基线已全面加固 =================="
    __SAY__ INFO "执行日志已保存: ${__LOG_FILE__}"
    __SAY__ INFO "配置备份目录: ${BACKUP_DIR}"
    if [ -n "${__INSTALL_FAILED_PKGS__}" ]; then
        __SAY__ WARN "以下包安装失败，需手工补装: ${__INSTALL_FAILED_PKGS__}"
    fi
    __SAY__ INFO "新内核参数配置与登录策略调整建议在适当时机重启服务器 (reboot) 后以取得最深度的优化支持。"
    if __ENV_YES__ "${AUTO_SSH}"; then
        __SAY__ WARN "SSH 已加固为仅密钥登录（PasswordAuthentication no / PermitRootLogin prohibit-password）：请先确认已配置公钥再断开当前会话"
    fi

    __CLEANUP_TMP__
}

__MAIN__ "$@"