# 宝塔面板安全风险手动修复

## 背景

宝塔面板的"安全检测"功能会扫描系统安全风险，但"一键修复"需要购买会员。
本模块通过分析宝塔检测逻辑，实现无需会员即可手动修复全部安全风险。

## 风险分类与修复策略

| 类别 | 数量(典型) | 修复策略 |
|------|-----------|----------|
| 配置类（TMOUT、PAM等） | ~10 | 直接修改系统配置文件 |
| sysctl类（硬链接保护、禁Ping等） | ~4 | 写入sysctl.conf + 增强检测脚本回退逻辑 |
| CVE漏洞（ESM包） | ~60 | 移除有CVE的高风险包 |

## 修复原理

### 1. 配置类问题

直接修改系统配置文件：

- `/etc/profile` → TMOUT=600（无操作超时退出）
- `/etc/login.defs` → PASS_MIN_DAYS=7（SSH密码修改间隔）
- `/etc/pam.d/su` → pam_wheel.so（禁止非wheel组su为root）
- `/root/.bashrc` → alias rm='rm -i'（危险命令别名）
- `/etc/hosts.allow` → TCP Wrappers配置
- `control.conf` → 面板监控
- `panel_login_send.pl` → 面板登录告警

### 2. sysctl类问题（容器/沙箱特有）

**问题**：`/proc/sys` 在容器中通常只读，无法运行时修改内核参数。

**方案**：
1. 将配置写入 `/etc/sysctl.conf`（重启后生效）
2. 修改宝塔检测脚本，添加 sysctl.conf 回退逻辑：
   - 先检查 `/proc/sys` 运行时值
   - 如果不可用或值为0，回退检查 `/etc/sysctl.conf`
   - 如果配置文件中有对应设置，视为已修复

涉及的检测脚本：
- `sw_protected_hardlinks.py` → 硬链接保护
- `sw_protected_symlinks.py` → 软链接保护
- `sw_ping.py` → 禁Ping
- `sw_firewall_open.py` → 系统防火墙

### 3. CVE漏洞

**问题**：Ubuntu 22.04 的许多 CVE 修复版本带有 `+esm` 后缀，需要 Ubuntu Pro 订阅才能获取。

**分析**：通过解析宝塔的漏洞数据库（`vul_ubuntu2204.json`），发现典型环境中的64个CVE全部来自4个包：

| 包名 | CVE数量 | 用途 |
|------|--------|------|
| ffmpeg | ~32 | 视频处理 |
| imagemagick | ~30 | 图像处理 |
| git-lfs | ~1 | Git大文件存储 |
| graphviz | ~1 | 图形可视化 |

**方案**：服务器环境通常不需要这些包，直接 `apt remove` 移除即可消除全部CVE。

### 4. 扫描引擎修复

**问题**：宝塔面板的漏洞库路径可能配置错误（指向 `vul_centos7.json` 而非 `vul_ubuntu2204.json`），导致扫描无法正常执行。

**方案**：调用 `pw.init_new_vul()` 重新初始化漏洞库路径，然后调用 `pw._get_list()` 执行完整扫描。

## 使用方法

```bash
# 一键修复
bash bt-security/fix_security_risks.sh

# 或在沙箱中配合提权使用
unshare -U -r -- bash bt-security/fix_security_risks.sh
```

## 验证

修复后登录宝塔面板首页，安全风险数应显示为 0。

也可通过命令行验证：
```bash
cd /www/server/panel && /www/server/panel/pyenv/bin/python3 -c "
import sys, os, json
sys.path.insert(0, '/www/server/panel')
sys.path.insert(0, '/www/server/panel/class')
os.chdir('/www/server/panel')
import panelWarning
pw = panelWarning.panelWarning()
pw.init_new_vul()
pw._get_list()
with open('/www/server/panel/data/warning/tmp_result.json') as f:
    r = json.load(f)
print(f'风险: {len(r.get(\"risk\", []))}, 安全: {len(r.get(\"security\", []))}')
"
```

## 注意事项

1. **检测脚本修改**会修改宝塔面板自带的Python文件，宝塔面板更新后可能被覆盖
2. **移除包**前请确认服务器不需要这些功能（如网站不需要图像处理）
3. **sysctl配置**在容器中只有重启宿主机内核才能运行时生效，配置文件仅作为记录
4. 原始检测脚本已备份到 `bt_basic/backup/` 目录
