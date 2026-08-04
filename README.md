# Linux Server SysInit & DevSec Hardening

Linux 服务器快速初始化、性能调优与 Dev-Sec 安全基线加固脚本。

## 功能概述

一键完成新装 Linux 服务器的以下工作：

| 模块 | 功能 | 交互 |
|------|------|------|
| 系统检测 | 自动识别 OS 发行版、包管理器、云环境、Init 系统 | — |
| 主机名设置 | 自定义或随机生成主机名，同步 `/etc/hosts` | 环境变量 `HOSTNAME` |
| 软件源检查 | 云环境保持厂商源，本地环境提示 | — |
| 基础工具安装 | 安装 vim/git/curl/chrony/htop 等常用工具 | — |
| 系统安全更新 | 可选执行全系统升级 | ✅ 交互确认 |
| SELinux | RHEL 系设为 Permissive 模式 | — |
| **防火墙** | iptables 默认 DROP + 自定义 IP:端口白名单 | ✅ **交互式配置** |
| 内核优化 | 高并发网络参数 + 安全基线（ASLR、rp_filter 等） | — |
| 文件句柄 | limits.d 独立文件，幂等写入 | — |
| OS 加固 | umask 027、密码策略、锁定系统账户、凭证文件权限 | — |
| 时区设置 | 可配置时区（默认 Asia/Shanghai） | 环境变量 `TZ` |
| 命令审计 | PROMPT_COMMAND 审计 + logrotate 轮转 | — |
| 禁用服务 | 关闭 postfix/rpcbind/exim4 等非必要服务 | — |
| **SSH 加固** | 禁用 root 密码登录、密钥认证、防锁死回滚 | ✅ **交互式配置** |

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
| `BACKUP_DIR` | `/var/backups/sysinit` | 配置文件修改备份目录 |
| `LOG_DIR` | `/var/log` | 执行日志保存目录 |
| `LOG_LEVEL` | `INFO` | 日志级别：`INFO` / `WARN` / `ERROR` / `DEBUG` |

### 示例

```bash
# 自定义主机名和时区，非交互模式
HOSTNAME=web-prod-01 TZ=Asia/Shanghai AUTO_FIREWALL=yes AUTO_SSH=yes bash sysinit.sh

# 自定义 SSH 端口
SSH_PORT=2222 bash sysinit.sh
```

## 交互式配置说明

### 防火墙交互

脚本会引导你完成以下配置：

1. **确认是否启用防火墙** — 默认推荐启用
2. **自动应用基础规则**：
   - 默认策略: `DROP`（拒绝所有入站）
   - 回环接口 (`lo`) 全部放行
   - 已建立连接 (`ESTABLISHED,RELATED`) 放行
   - SSH 端口放行（默认 22，可通过 `SSH_PORT` 修改）
   - ICMP ping 有限速率放行
3. **自定义 IP:端口规则** — 循环添加，支持：
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
   - `MaxAuthTries 4`、`ClientAliveInterval 300`
5. **防锁死机制**：
   - 修改前自动备份配置
   - `sshd -t` 语法校验
   - 校验失败自动回滚备份，防止远程断连

## 安全注意事项

1. **防火墙默认 DROP**：应用后确保你已放行 SSH 端口，否则会失去远程连接。
2. **SSH 密钥认证**：启用 `PasswordAuthentication no` 前，请确认已配置 SSH 公钥。
3. **SELinux Permissive**：脚本将 SELinux 设为 permissive 模式，生产环境建议后续按需调整为 enforcing。
4. **备份机制**：所有 `/etc` 下的修改会备份到 `BACKUP_DIR`（默认 `/var/backups/sysinit/`）。
5. **执行日志**：运行日志自动保存到 `LOG_DIR/sysinit-<时间戳>.log`（默认 `/var/log/`），便于审计与排错。
6. **幂等性**：脚本执行成功后会在 `/opt/.server.init.executed` 写入标记，如需重新执行请删除此文件或确认覆盖提示。
7. **错误处理**：脚本启用 `set -euo pipefail` 与 ERR trap，任何步骤失败都会输出错误位置、日志路径与备份路径后退出。

## 文件结构

```
.
├── sysinit.sh          # 主脚本
└── README.md           # 项目说明
```

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 2.1.0 | 2026-08-04 | 交互式防火墙/SSH、兼容性增强、P0 缺陷修复、日志与备份完善 |
| 2.0.0 | 2026-08-04 | Dev-Sec 安全基线 + Anti-Lockout SSH 回滚 |
| 1.0.0 | — | 初始版本 |
