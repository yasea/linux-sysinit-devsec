# Linux Server SysInit & DevSec Hardening

Linux 服务器快速初始化、性能调优与 Dev-Sec 安全基线加固脚本。

## 功能概述

一键完成新装 Linux 服务器的以下工作：

| 模块 | 功能 | 交互 | 开关 |
|------|------|------|------|
| 系统检测 | 自动识别 OS 发行版、包管理器、云环境、Init 系统 | — | — |
| 主机名设置 | 自定义或随机生成主机名，同步 `/etc/hosts` | — | `HOSTNAME` |
| 软件源检查 | 云环境保持厂商源，本地环境提示 | — | — |
| 基础工具安装 | 逐包安装 vim/git/curl/chrony/htop 等（失败汇总） | — | — |
| 系统安全更新 | 可选执行全系统升级 | ✅ 交互确认 | — |
| SELinux | RHEL 系设为 Permissive 模式 | — | — |
| **防火墙** | ufw 默认 deny incoming，SSH 限源 | ✅ **交互式配置** | `SSH_ALLOW_IPS` |
| 内核优化 | 高并发网络参数 + 安全基线（ASLR、rp_filter 等） | — | — |
| 文件句柄 | limits.d 独立文件，幂等写入 | — | — |
| OS 加固 | umask 022 + USERGROUPS_ENAB no、密码策略、锁定系统账户、凭证文件权限 | — | — |
| 时区设置 | 可配置时区（默认 Asia/Shanghai），云环境优化 NTP 源 | — | `TZ` |
| 命令审计 | PROMPT_COMMAND 审计 + logrotate 轮转（666+chattr +a） | — | — |
| 禁用服务 | 关闭 postfix/rpcbind/exim4 等非必要服务 | — | — |
| **SSH 加固** | 禁用 root 密码登录、密钥认证、防锁死回滚、修正 cloud-init 覆盖 | ✅ **交互式配置** | — |
| **swap** | swapfile + fstab 持久化（默认 4G，可通过 `SWAP_SIZE` 调整） | — | `ENABLE_SWAP` |
| **fail2ban** | sshd jail 安装与配置 | — | `ENABLE_FAIL2BAN` |
| **关闭 IPv6** | sysctl + ufw + sshd + nginx 全链路关闭 | — | `DISABLE_IPV6` |
| **journald** | 持久化 256M/30天 | — | `ENABLE_JOURNALD` |
| **unattended** | 自动安全更新 | — | `ENABLE_UNATTENDED` |
| **sysstat** | sar 系统活动采集 | — | `ENABLE_SYSSTAT` |
| **auditd** | 系统级审计（认证/sudo/cron/模块/权限） | — | `ENABLE_AUDITD` |
| **modprobe 黑名单** | 禁用高风险内核模块（cramfs/dccp/sctp/hfs 等） | — | `ENABLE_MODPROBE_HARDEN` |
| **安全工具** | rkhunter/clamav/lynis + 自动化扫描 cron | — | `ENABLE_SECURITY_TOOLS` |
| **nginx 安全头** | 检测到 nginx 时应用安全响应头 | — | `ENABLE_NGINX_HARDEN` |
| **服务发现** | 扫描监听端口 + 推断 enabled 服务端口 + 用户确认"不可触碰" | ✅ **交互式确认** | `EXTRA_ALLOW_PORTS` |
| **分级加固** | `minimal`/`standard`/`enhanced` 一键启用对应安全模块 | — | `HARDENING_LEVEL` |
| **合规报告** | CIS 基线检查项（ASLR/SSH/ufw/auditd 等 12 项） | — | — |
| **/data 目录** | 创建 apps/scripts/backups/nginx-sites/creds 标准结构 | — | `CREATE_DATA_DIRS` |

## 支持的操作系统

| 发行版 | 包管理器 | 状态 |
|--------|----------|------|
| Debian / Ubuntu | `apt-get` | ✅ 完整支持 |
| CentOS / Rocky / AlmaLinux | `yum` / `dnf` | ✅ 完整支持 |
| Amazon Linux / Aliyun Linux | `yum` / `dnf` | ✅ 完整支持 |
| openEuler | `yum` / `dnf` | ✅ 完整支持 |
| Fedora / RHEL | `dnf` / `yum` | ✅ 完整支持 |
| openSUSE / SUSE Linux | `zypper` | ✅ 基础支持 |
| Alpine Linux | `apk` | ✅ 基础支持 |
| Arch Linux | `pacman` | ✅ 基础支持 |

> 其他基于 `ID_LIKE` 的衍生版会尝试兼容模式运行。

## 使用方法

### 基本用法

```bash
# 直接运行（交互模式）
bash sysinit.sh

# 非交互模式（使用默认推荐配置）
AUTO_FIREWALL=yes AUTO_SSH=yes bash sysinit.sh
```

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `AUTO_FIREWALL` | (空) | 设为 `yes` 跳过防火墙交互，使用默认推荐规则 |
| `AUTO_SSH` | (空) | 设为 `yes` 跳过 SSH 交互，使用默认推荐配置 |
| `HOSTNAME` | (随机生成) | 自定义主机名 |
| `TZ` | `Asia/Shanghai` | 系统时区 |
| `SSH_PORT` | `22` | SSH 服务端口（防火墙放行此端口） |
| `SSH_ALLOW_IPS` | (空) | SSH 放行源 IP，逗号分隔（如 `1.2.3.4,5.6.7.8`）。留空时：若自动白名单生效则只放行当前 IP，否则放行所有来源并告警 |
| `AUTO_WHITELIST_CURRENT_IP` | `yes` | 非交互且 `AUTO_FIREWALL=yes` 时，自动将当前连接 IP 加入 SSH 白名单（防止误锁） |
| `ENABLE_SWAP` | `no` | 设为 `yes` 创建 4G swapfile |
| `SWAP_SIZE` | `4G` | swap 大小（如 `4G`/`8G`） |
| `ENABLE_FAIL2BAN` | `no` | 设为 `yes` 安装并配置 fail2ban sshd jail |
| `DISABLE_IPV6` | `no` | 设为 `yes` 关闭 IPv6（sysctl+ufw+sshd+nginx） |
| `ENABLE_JOURNALD` | `no` | 设为 `yes` 配置 journald 持久化（256M/30天） |
| `ENABLE_UNATTENDED` | `no` | 设为 `yes` 启用 unattended-upgrades 自动安全更新 |
| `ENABLE_SYSSTAT` | `no` | 设为 `yes` 安装 sysstat/sar |
| `ENABLE_AUDITD` | `no` | 设为 `yes` 启用 auditd 系统级审计（认证/sudo/cron/模块/权限） |
| `ENABLE_MODPROBE_HARDEN` | `no` | 设为 `yes` 禁用高风险内核模块（cramfs/dccp/sctp/hfs 等） |
| `ENABLE_SECURITY_TOOLS` | `no` | 设为 `yes` 安装 rkhunter/clamav/lynis + 自动化扫描 cron |
| `ENABLE_NGINX_HARDEN` | `no` | 设为 `yes` 检测到 nginx 时应用安全响应头 |
| `HARDENING_LEVEL` | (空) | 分级加固：`minimal`/`standard`/`enhanced`，一键启用对应安全模块 |
| `EXTRA_ALLOW_PORTS` | (空) | 额外放行端口（逗号分隔），覆盖服务发现时序盲区（服务在扫描后才启动时） |
| `CREATE_DATA_DIRS` | `no` | 设为 `yes` 创建 `/data` 业务目录结构 |
| `BACKUP_DIR` | `/var/backups/sysinit` | 配置文件修改备份目录 |
| `LOG_DIR` | `/var/log` | 执行日志保存目录 |
| `LOG_LEVEL` | `INFO` | 日志级别：`INFO` / `WARN` / `ERROR` / `DEBUG` |

### 示例

```bash
# 全自动（推荐云服务器开箱即用）
HOSTNAME=myhost TZ=Asia/Shanghai SSH_ALLOW_IPS=1.2.3.4 \
ENABLE_SWAP=yes ENABLE_FAIL2BAN=yes DISABLE_IPV6=yes \
ENABLE_JOURNALD=yes ENABLE_UNATTENDED=yes ENABLE_SYSSTAT=yes \
CREATE_DATA_DIRS=yes \
AUTO_FIREWALL=yes AUTO_SSH=yes bash sysinit.sh

# 自定义 SSH 端口 + SSH 限源
SSH_PORT=2222 SSH_ALLOW_IPS=10.0.0.0/8 bash sysinit.sh

# 最小化（仅基础加固，不加可选模块）
AUTO_FIREWALL=yes AUTO_SSH=yes bash sysinit.sh

# 分级加固：standard 启用 auditd/modprobe/fail2ban/journald，enhanced 再加安全工具/nginx/unattended
HARDENING_LEVEL=standard AUTO_FIREWALL=yes AUTO_SSH=yes bash sysinit.sh
HARDENING_LEVEL=enhanced AUTO_FIREWALL=yes AUTO_SSH=yes bash sysinit.sh

# 额外放行端口（覆盖服务在扫描后才启动的时序盲区）
EXTRA_ALLOW_PORTS=428,8443 AUTO_FIREWALL=yes AUTO_SSH=yes bash sysinit.sh
```

## 交互式配置说明

### 防火墙交互

脚本会引导你完成以下配置：

1. **确认是否启用防火墙** — 默认推荐启用
2. **是否自动将当前连接的 IP 加入白名单** — 默认推荐启用（防止误锁；非交互时由 `AUTO_WHITELIST_CURRENT_IP=yes` 控制）
3. **自动应用基础规则**：
   - 默认策略: DROP/deny（拒绝所有入站）
   - 回环接口 (`lo`) 全部放行
   - 已建立连接 (`ESTABLISHED,RELATED`) 放行
   - SSH 端口放行（默认 22，可通过 `SSH_PORT` 修改；`SSH_ALLOW_IPS` 限源）
   - ICMP ping 有限速率放行
4. **自定义 IP:端口规则** — 循环添加，支持：
   - 指定源 IP（留空表示所有来源）
   - 目标端口号
   - 协议（tcp/udp）

### SSH 加固交互

脚本会引导你确认以下配置：

1. **确认是否应用 SSH 加固** — 默认推荐启用
2. **禁用 root 密码登录** — 推荐 `prohibit-password`
3. **禁用密码认证，仅允许密钥登录** — 推荐启用
4. **自动应用安全参数**：
   - `UseDNS no`、`GSSAPIAuthentication no`
   - `PermitEmptyPasswords no`、`X11Forwarding no`
   - `MaxAuthTries 4`、`LoginGraceTime 60`、`ClientAliveInterval 300`
   - `AddressFamily inet`（`DISABLE_IPV6=yes` 时）
5. **修正 cloud-init 覆盖**：检测 `sshd_config.d/*.conf` 中的 `PasswordAuthentication yes` 并修正（sshd 首值生效机制坑）
6. **防锁死机制**：
   - 修改前自动备份配置
   - `sshd -t` 语法校验
   - 校验失败自动回滚备份，防止远程断连

## 安全注意事项

1. **防火墙默认 deny/drop**：应用后确保你已放行 SSH 端口，否则会失去远程连接。建议设置 `SSH_ALLOW_IPS` 限源。
2. **SSH 密钥认证**：启用 `PasswordAuthentication no` 前，请确认已配置 SSH 公钥。
3. **umask 022**：v2.2.0 起改为 022（云服务器多用户/容器场景；027 会导致容器挂载文件 403）。同时设 `USERGROUPS_ENAB no`。
4. **命令审计权限**：v2.2.0 起审计文件 666 + `chattr +a`（非 root 用户可写追加，不可删改）。
5. **SELinux Permissive**：脚本将 SELinux 设为 permissive 模式，生产环境建议后续按需调整为 enforcing。
6. **备份机制**：所有 `/etc` 下的修改会备份到 `BACKUP_DIR`（默认 `/var/backups/sysinit/`）。
7. **执行日志**：运行日志自动保存到 `LOG_DIR/sysinit-<时间戳>.log`（默认 `/var/log/`），便于审计与排错。
8. **幂等性**：脚本执行成功后会在 `/opt/.server.init.executed` 写入标记，如需重新执行请删除此文件或确认覆盖提示。
9. **错误处理**：脚本启用 `set -euo pipefail` 与 ERR trap，任何步骤失败都会输出错误位置、日志路径与备份路径后退出。安装失败的包会在末尾汇总告警。

## 文件结构

```
.
├── sysinit.sh          # 主脚本
└── README.md           # 项目说明
```

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 2.3.1 | 2026-08-15 | **代码审计修复**：合规报告 `sshd -T` 改单次执行+`|| true` 兜底（避免 `set -e` 退出）、服务发现端口提取管道补 `|| true`（`pipefail` 下 grep 无匹配不退出）、modprobe `lsmod` 模块名兼容 `-`/`_` 两种写法、提取 `__CHECK__` 单行辅助消除重复代码、清理 `tr ' ' '`/`changed` 死代码、dry-run 计划与执行顺序同步；README 功能表补列 2.3.0 新增模块、示例区补充 `HARDENING_LEVEL`/`EXTRA_ALLOW_PORTS` 用法 |
| 2.3.0 | 2026-08-15 | **安全纵深增强**：新增服务发现与"不可触碰"确认（对齐 hardening-skill 阶段0）、SSH 公钥存在性预检防逻辑锁死、auditd 系统审计、内核模块禁用（modprobe 黑名单）、安全工具+自动化扫描 cron（rkhunter/clamav/lynis）、nginx 安全头、分级加固等级 `HARDENING_LEVEL`、合规报告、`--dry-run` 预演、flock 并发锁、备份清理策略、SSH drop-in 全参数覆盖、`tcp_tw_reuse` NAT 风险注释；**服务发现增强**：推断 enabled 服务端口 + `EXTRA_ALLOW_PORTS` 显式声明，覆盖"服务在扫描后才启动"的时序盲区 |
| 2.2.2 | 2026-08-15 | 修复：`__GET_CURRENT_IP__` ss 兜底死代码（自动白名单失效）、`__SAY__` 日志级别颠倒导致 WARN/ERROR 被吞、`LOG_LEVEL` 环境变量失效、移除废弃的 sshd `Protocol`、`nf_conntrack_max` 按内存动态计算；增强：批量安装包+失败回退、按云厂商映射 NTP、区分本地虚拟机/云环境、fail2ban backend 按 init 系统、`--help` 与 bash 版本检查、`/etc/hosts` sed 容错 |
| 2.2.0 | 2026-08-14 | P0 修复：apt 拆包失败、iptables LOG 语法、umask 027→022+USERGROUPS_ENAB、防火墙改 ufw；P1 增强：SSH 补 LoginGraceTime/AddressFamily/cloud-init 修正、审计权限 666、新增 swap/fail2ban/IPv6/journald/unattended/sysstat/data目录/deploy账号可选模块；P2：SSH 限源、nf_conntrack modprobe、云环境 NTP 优化、错误汇总 |
| 2.2.1 | 2026-08-14 | 防火墙统一为 ufw（移除 iptables 后端）；修复 swap dd 回退单位错误、ufw reset 幂等性；移除 deploy 部署账号模块 |
| 2.1.0 | 2026-08-04 | 交互式防火墙/SSH、兼容性增强、P0 缺陷修复、日志与备份完善 |
| 2.0.0 | 2026-08-04 | Dev-Sec 安全基线 + Anti-Lockout SSH 回滚 |
| 1.0.0 | — | 初始版本 |