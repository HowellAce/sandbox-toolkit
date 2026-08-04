# Chrome Extension Proxy - TRAE 沙箱浏览器增强

## 问题

TRAE 沙箱中的 Chrome (Chromium 150.0.7871.181) 无法安装浏览器扩展。

### 根因分析

通过 CDP (Chrome DevTools Protocol) 深入分析，发现以下原因：

1. **启动参数限制**: Chrome 使用 `--deny-permission-prompts` 标志启动，导致 `canLoadUnpacked: false`
2. **Chrome 在独立容器中运行**: 二进制位于 `/usr/lib/chromium/chromium`，用户数据在 `/tmp/chrome-data`，但从沙箱无法访问其文件系统
3. **Chrome Web Store 被封锁**: `chromewebstore.google.com` 连接被关闭 (`ERR_CONNECTION_CLOSED`)
4. **策略文件无效**: 在 `/etc/opt/chrome/policies/managed/` 和 `/etc/chromium/policies/managed/` 创建的策略文件未被 Chrome 加载（chrome://policy 页面显示无策略）

### Chrome 完整启动参数

```
/usr/lib/chromium/chromium
  --show-component-extension-options
  --enable-gpu-rasterization
  --no-default-browser-check
  --disable-pings
  --media-router=0
  --enable-remote-extensions
  --load-extension          ← 存在但无路径
  --remote-debugging-port=9222
  --remote-debugging-address=127.0.0.1
  --user-data-dir=/tmp/chrome-data
  --deny-permission-prompts  ← 阻止扩展安装
  --disable-notifications
  --disable-background-networking
  --mute-audio
  --disable-audio-output
  --disable-component-update
  --renderer-process-limit=4
  ...
```

### 尝试过但失败的方法

| 方法 | 结果 | 原因 |
|------|------|------|
| Chrome 策略文件 | 无效 | Chrome 在独立容器中，不读取沙箱的策略文件 |
| `developerPrivate.loadUnpacked()` | 被拒绝 | "Extension installation is blocked by policy" |
| `developerPrivate.loadDirectory()` | 签名不匹配 | 需要 DirectoryEntry 对象，不接受字符串路径 |
| Chrome Web Store 安装 | 连接被拒 | `ERR_CONNECTION_CLOSED` |
| 修改 Chrome Preferences | 无法访问 | Chrome 文件系统在独立容器中 |
| 重启 Chrome 带不同参数 | 无法实现 | 无法控制 Chrome 启动过程 |
| CDP 文件选择器拦截 | 超时 | WebSocket 事件未被正确接收 |

## 解决方案: CDP 用户脚本注入

通过 CDP 的 `Page.addScriptToEvaluateOnNewDocument` 方法向所有页面注入自定义 JavaScript，实现类似浏览器扩展的功能。

### 原理

1. 连接 Chrome 的 CDP 端点 (`127.0.0.1:9222`)
2. 轮询发现新的标签页
3. 对每个标签页调用 `Page.addScriptToEvaluateOnNewDocument` 注入脚本
4. 脚本在页面加载时自动执行，并持久化到页面导航
5. 作为 supervisor 服务运行，开机自动启动

### 内置脚本

| 脚本 | 功能 |
|------|------|
| `status-bar` | 顶部彩色状态条 + "TRAE Scripts" 徽章 |
| `dark-mode` | 暗色模式切换按钮 |
| `dev-tools` | 开发者快捷工具面板 |
| `ad-blocker` | 简易广告拦截器 |
| `auto-refresh` | Error 1033 自动检测和刷新 |

### 使用方法

```bash
# 安装为 supervisor 服务（开机自启）
python3 /workspace/chrome-extension-proxy/chrome-userscript-injector.py --install

# 列出可用脚本
python3 /workspace/chrome-extension-proxy/chrome-userscript-injector.py --list

# 注入自定义脚本文件
python3 /workspace/chrome-extension-proxy/chrome-userscript-injector.py --inject /path/to/script.js

# 前台运行（调试用）
python3 /workspace/chrome-extension-proxy/chrome-userscript-injector.py --daemon
```

### 添加自定义脚本

1. 创建 `.js` 文件，放入 `/workspace/chrome-extension-proxy/userscripts/` 目录
2. 重启服务: `supervisorctl restart userscript-injector`
3. 脚本会自动注入到所有新打开的标签页

### 限制

- 脚本注入对 `chrome://` 页面无效（Chrome 安全限制）
- 每次沙箱重置后，注入状态会丢失（但 supervisor 会自动重启服务）
- 无法使用 Chrome 扩展 API（如 `chrome.storage`、`chrome.tabs` 等）
- 无法修改浏览器 UI（如工具栏按钮、右键菜单）

## 文件结构

```
chrome-extension-proxy/
├── chrome-userscript-injector.py   # 主脚本（注入器 + 守护进程）
├── userscripts/                     # 自定义脚本目录
└── README.md                        # 本文档
```
