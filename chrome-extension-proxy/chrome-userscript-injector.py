#!/usr/bin/env python3
"""
chrome-userscript-injector.py - TRAE Chrome 用户脚本注入器

由于 TRAE 沙箱中的 Chrome (Chromium 150) 启动时使用了 --deny-permission-prompts 标志，
导致 canLoadUnpacked=false，无法通过常规方式安装扩展。

本脚本通过 CDP (Chrome DevTools Protocol) 的 Page.addScriptToEvaluateOnNewDocument
方法向所有页面注入自定义 JavaScript，实现类似浏览器扩展的功能。

功能：
1. 自动发现新标签页并注入脚本
2. 支持多个用户脚本（暗色模式、广告拦截、开发者工具等）
3. 脚本持久化（通过 CDP 的 addScriptToEvaluateOnNewDocument）
4. 可注册为 supervisor 服务，开机自动运行

用法：
  python3 chrome-userscript-injector.py              # 前台运行
  python3 chrome-userscript-injector.py --install     # 安装为 supervisor 服务
  python3 chrome-userscript-injector.py --list        # 列出已注入的脚本
  python3 chrome-userscript-injector.py --inject FILE # 注入自定义脚本文件
"""

import json
import os
import sys
import time
import signal
import urllib.request
import websocket
import argparse
import threading
from pathlib import Path

# Configuration
CDP_BASE = "http://127.0.0.1:9222"
SCRIPTS_DIR = Path(__file__).parent / "userscripts"
INJECTION_STATE = Path("/workspace/logs/cdp-injection-state.json")
LOG_FILE = Path("/workspace/logs/userscript-injector.log")
POLL_INTERVAL = 5  # seconds between checks for new tabs

# Ensure directories exist
os.makedirs(SCRIPTS_DIR, exist_ok=True)
os.makedirs(Path("/workspace/logs"), exist_ok=True)

# ============================================================
# Built-in Userscripts
# ============================================================

BUILTIN_SCRIPTS = {
    "status-bar": """
// TRAE Status Bar - Shows that userscript injection is active
(function() {
    if (window.__traeStatusBar) return;
    window.__traeStatusBar = true;

    var bar = document.createElement('div');
    bar.id = 'trae-status-bar';
    bar.style.cssText = 'position:fixed;top:0;left:0;right:0;height:3px;z-index:2147483647;background:linear-gradient(90deg,#2563eb,#7c3aed,#ec4899);pointer-events:none;';
    document.documentElement.appendChild(bar);

    var badge = document.createElement('div');
    badge.style.cssText = 'position:fixed;top:8px;right:8px;z-index:2147483647;background:rgba(37,99,235,0.9);color:white;padding:4px 10px;border-radius:4px;font-family:system-ui;font-size:11px;font-weight:600;pointer-events:auto;cursor:pointer;box-shadow:0 2px 6px rgba(0,0,0,0.3);transition:opacity 0.3s;';
    badge.textContent = 'TRAE Scripts';
    badge.title = 'CDP Userscript Injection Active';
    badge.onclick = function() {
        alert('TRAE CDP Userscript Injection\\n\\n' +
              'Active scripts: ' + (window.__traeActiveScripts || []).join(', ') + '\\n' +
              'This replaces Chrome extensions in the TRAE sandbox.');
    };
    document.documentElement.appendChild(badge);

    // Auto-fade badge after 5 seconds
    setTimeout(function() { badge.style.opacity = '0.3'; }, 5000);
    badge.addEventListener('mouseenter', function() { badge.style.opacity = '1'; });
    badge.addEventListener('mouseleave', function() { badge.style.opacity = '0.3'; });

    window.__traeActiveScripts = window.__traeActiveScripts || [];
    window.__traeActiveScripts.push('status-bar');
})();
""",

    "dark-mode": """
// Dark Mode Toggle - Adds a dark mode toggle button
(function() {
    if (window.__traeDarkMode) return;
    window.__traeDarkMode = true;

    var darkCSS = document.createElement('style');
    darkCSS.id = 'trae-dark-mode';
    darkCSS.textContent = `
        html.trae-dark { filter: invert(1) hue-rotate(180deg) brightness(0.9) contrast(0.9); }
        html.trae-dark img, html.trae-dark video, html.trae-dark canvas { filter: invert(1) hue-rotate(180deg); }
        html.trae-dark #trae-status-bar { filter: none; }
    `;
    document.head.appendChild(darkCSS);

    var btn = document.createElement('button');
    btn.style.cssText = 'position:fixed;top:40px;right:8px;z-index:2147483647;background:#1f2937;color:#f9fafb;border:none;width:32px;height:32px;border-radius:50%;cursor:pointer;font-size:16px;box-shadow:0 2px 6px rgba(0,0,0,0.3);display:flex;align-items:center;justify-content:center;';
    btn.textContent = '🌙';
    btn.title = 'Toggle Dark Mode (TRAE)';
    btn.onclick = function() {
        document.documentElement.classList.toggle('trae-dark');
        btn.textContent = document.documentElement.classList.contains('trae-dark') ? '☀️' : '🌙';
    };
    document.documentElement.appendChild(btn);

    window.__traeActiveScripts = window.__traeActiveScripts || [];
    window.__traeActiveScripts.push('dark-mode');
})();
""",

    "dev-tools": """
// Developer Helper - Adds quick access to common dev functions
(function() {
    if (window.__traeDevTools) return;
    window.__traeDevTools = true;

    var panel = document.createElement('div');
    panel.style.cssText = 'position:fixed;bottom:8px;right:8px;z-index:2147483647;background:rgba(17,24,39,0.95);color:#f9fafb;padding:8px;border-radius:6px;font-family:monospace;font-size:11px;box-shadow:0 4px 12px rgba(0,0,0,0.4);min-width:200px;';
    panel.innerHTML = '<div style="font-weight:bold;margin-bottom:4px;color:#60a5fa;">🛠 Dev Quick Tools</div>';

    var buttons = [
        { label: '📋 Copy URL', action: function() { navigator.clipboard.writeText(window.location.href).then(function(){ alert('URL copied!'); }); } },
        { label: '🔍 View Source', action: function() { window.open('view-source:' + window.location.href); } },
        { label: '📱 Mobile View', action: function() { document.body.style.zoom = document.body.style.zoom === '0.5' ? '1' : '0.5'; } },
        { label: '🔒 Check SSL', action: function() { alert('Protocol: ' + window.location.protocol + '\\nHost: ' + window.location.hostname); } },
        { label: '📊 Page Info', action: function() { alert('Title: ' + document.title + '\\nURL: ' + window.location.href + '\\nSize: ' + document.documentElement.innerHTML.length + ' bytes'); } },
    ];

    buttons.forEach(function(b) {
        var btn = document.createElement('div');
        btn.textContent = b.label;
        btn.style.cssText = 'padding:3px 6px;cursor:pointer;border-radius:3px;transition:background 0.15s;';
        btn.onmouseover = function() { btn.style.background = 'rgba(96,165,250,0.3)'; };
        btn.onmouseout = function() { btn.style.background = 'transparent'; };
        btn.onclick = b.action;
        panel.appendChild(btn);
    });

    var toggle = document.createElement('div');
    toggle.textContent = '➖';
    toggle.style.cssText = 'position:absolute;top:-12px;right:-8px;background:#ef4444;color:white;width:18px;height:18px;border-radius:50%;cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:10px;';
    var content = panel;
    var hidden = false;
    toggle.onclick = function() {
        hidden = !hidden;
        content.style.height = hidden ? '32px' : 'auto';
        content.style.overflow = hidden ? 'hidden' : 'visible';
        toggle.textContent = hidden ? '➕' : '➖';
    };
    panel.appendChild(toggle);

    document.documentElement.appendChild(panel);

    window.__traeActiveScripts = window.__traeActiveScripts || [];
    window.__traeActiveScripts.push('dev-tools');
})();
""",

    "ad-blocker": """
// Simple Ad Blocker - Hides common ad elements
(function() {
    if (window.__traeAdBlock) return;
    window.__traeAdBlock = true;

    var adSelectors = [
        '[id*="ad-"]', '[id*="ad_"]', '[id*="ads-"]', '[id*="ads_"]',
        '[class*="advertisement"]', '[class*="ad-container"]', '[class*="ad-banner"]',
        '[class*="ad-slot"]', '[class*="google-ad"]', '[class*="adsbygoogle"]',
        'ins.adsbygoogle', 'iframe[src*="doubleclick"]', 'iframe[src*="googlesyndication"]',
        'div[id*="google_ads"]', 'div[data-ad]', '[class*="promo-box"]',
    ];

    var style = document.createElement('style');
    style.textContent = adSelectors.join(', ') + ' { display: none !important; }';
    document.head.appendChild(style);

    // Also block ad-related network requests
    if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function(url, options) {
            if (typeof url === 'string' && (url.includes('doubleclick') || url.includes('googlesyndication') || url.includes('googleads'))) {
                return new Promise(function() {});  // Never resolves
            }
            return origFetch.apply(this, arguments);
        };
    }

    window.__traeActiveScripts = window.__traeActiveScripts || [];
    window.__traeActiveScripts.push('ad-blocker');
})();
""",

    "auto-refresh": """
// Auto Refresh Monitor - Detects page crashes and offers reload
(function() {
    if (window.__traeAutoRefresh) return;
    window.__traeAutoRefresh = true;

    // Monitor for Error 1033 (cloudflared tunnel issues)
    var bodyText = document.body ? document.body.innerText : '';
    if (bodyText.includes('1033') || bodyText.includes('Error 1033')) {
        var banner = document.createElement('div');
        banner.style.cssText = 'position:fixed;top:0;left:0;right:0;background:#dc2626;color:white;padding:8px;text-align:center;font-family:system-ui;z-index:2147483647;';
        banner.innerHTML = '⚠️ Error 1033 detected. <button onclick="location.reload()" style="background:white;color:#dc2626;border:none;padding:2px 12px;border-radius:3px;cursor:pointer;margin-left:8px;">Reload</button> <span id="trae-reload-timer">Auto-reload in 10s</span>';
        document.body.appendChild(banner);

        var countdown = 10;
        var timer = setInterval(function() {
            countdown--;
            var el = document.getElementById('trae-reload-timer');
            if (el) el.textContent = 'Auto-reload in ' + countdown + 's';
            if (countdown <= 0) {
                clearInterval(timer);
                location.reload();
            }
        }, 1000);
    }

    window.__traeActiveScripts = window.__traeActiveScripts || [];
    window.__traeActiveScripts.push('auto-refresh');
})();
""",
}


# ============================================================
# CDP Communication
# ============================================================

def log(msg):
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    with open(LOG_FILE, 'a') as f:
        f.write(line + '\n')


def cdp_send(ws, method, params=None, msg_id=1, timeout=10):
    msg = {"id": msg_id, "method": method}
    if params:
        msg["params"] = params
    ws.send(json.dumps(msg))
    ws.settimeout(timeout)
    while True:
        result = json.loads(ws.recv())
        if result.get("id") == msg_id:
            return result


def connect(ws_url):
    return websocket.create_connection(ws_url, timeout=30, suppress_origin=True)


def get_targets():
    try:
        resp = urllib.request.urlopen(f"{CDP_BASE}/json/list", timeout=5)
        return json.loads(resp.read())
    except Exception as e:
        log(f"Error getting targets: {e}")
        return []


def get_browser_ws():
    try:
        resp = urllib.request.urlopen(f"{CDP_BASE}/json/version", timeout=5)
        data = json.loads(resp.read())
        return data.get("webSocketDebuggerUrl")
    except:
        return None


def load_state():
    if INJECTION_STATE.exists():
        try:
            return json.loads(INJECTION_STATE.read_text())
        except:
            pass
    return {"injected_tabs": {}, "scripts": list(BUILTIN_SCRIPTS.keys())}


def save_state(state):
    INJECTION_STATE.write_text(json.dumps(state, indent=2))


def inject_script_into_tab(ws_url, script_name, script_source):
    """Inject a script into a specific tab."""
    try:
        ws = connect(ws_url)
        cdp_send(ws, "Runtime.enable")
        cdp_send(ws, "Page.enable")

        # Add script for future navigations
        result = cdp_send(ws, "Page.addScriptToEvaluateOnNewDocument", {
            "source": script_source
        })

        # Also execute immediately
        cdp_send(ws, "Runtime.evaluate", {
            "expression": script_source,
            "returnByValue": True
        })

        ws.close()
        return True
    except Exception as e:
        log(f"  Error injecting {script_name}: {e}")
        return False


def inject_all_scripts(tab_id, tab_url, ws_url, state):
    """Inject all active scripts into a tab."""
    if tab_id in state["injected_tabs"]:
        return  # Already injected

    # Skip chrome:// pages except extensions
    if tab_url.startswith("chrome://") and "extensions" not in tab_url:
        return

    log(f"Injecting scripts into tab {tab_id} ({tab_url[:60]})")

    for script_name in state["scripts"]:
        script_source = BUILTIN_SCRIPTS.get(script_name, "")
        if not script_source:
            # Load from file
            script_file = SCRIPTS_DIR / f"{script_name}.js"
            if script_file.exists():
                script_source = script_file.read_text()
            else:
                continue

        inject_script_into_tab(ws_url, script_name, script_source)

    state["injected_tabs"][tab_id] = {
        "url": tab_url,
        "time": time.strftime('%Y-%m-%dT%H:%M:%S')
    }
    save_state(state)


def run_daemon():
    """Main daemon loop - monitors for new tabs and injects scripts."""
    log("TRAE Chrome Userscript Injector daemon started")
    log(f"Scripts directory: {SCRIPTS_DIR}")
    log(f"Active scripts: {', '.join(BUILTIN_SCRIPTS.keys())}")

    state = load_state()
    log(f"Loaded state: {len(state['injected_tabs'])} tabs already injected")

    # Set up auto-attach for new targets via browser WebSocket
    browser_ws_url = get_browser_ws()
    if not browser_ws_url:
        log("ERROR: Cannot connect to Chrome CDP endpoint")
        return

    # Use browser-level CDP to set up auto-attach
    try:
        browser_ws = connect(browser_ws_url)
        cdp_send(browser_ws, "Target.setDiscoverTargets", {"discover": True})
        log("Connected to browser-level CDP, target discovery enabled")
        browser_ws.close()
    except Exception as e:
        log(f"Warning: Could not set up auto-attach: {e}")

    while True:
        try:
            targets = get_targets()
            page_targets = [t for t in targets if t.get("type") == "page"]

            for target in page_targets:
                tab_id = target.get("id", "")
                tab_url = target.get("url", "")
                ws_url = target.get("webSocketDebuggerUrl", "")

                if not ws_url:
                    continue

                # Check if tab was already injected or if URL changed
                prev = state["injected_tabs"].get(tab_id, {})
                if prev and prev.get("url") == tab_url:
                    continue  # Same URL, already injected

                inject_all_scripts(tab_id, tab_url, ws_url, state)

            # Clean up closed tabs from state
            active_ids = {t.get("id") for t in targets}
            removed = [tid for tid in list(state["injected_tabs"].keys()) if tid not in active_ids]
            for tid in removed:
                del state["injected_tabs"][tid]
            if removed:
                save_state(state)
                log(f"Cleaned up {len(removed)} closed tabs")

        except Exception as e:
            log(f"Error in main loop: {e}")

        time.sleep(POLL_INTERVAL)


def install_as_service():
    """Install as a supervisor service."""
    conf = """[program:userscript-injector]
command=/usr/bin/python3 /workspace/chrome-extension-proxy/chrome-userscript-injector.py
directory=/workspace/chrome-extension-proxy
autostart=true
autorestart=true
startretries=3
stdout_logfile=/workspace/logs/userscript-injector.stdout.log
stderr_logfile=/workspace/logs/userscript-injector.stderr.log
environment=PYTHONPATH="/workspace"
"""
    conf_path = "/workspace/supervisor-userscript.conf"
    with open(conf_path, 'w') as f:
        f.write(conf)

    # Add to supervisor
    os.system('grep -q "supervisor-userscript" /app/supervisord.conf || echo "[include]\\nfiles = /workspace/supervisor-bt.conf /workspace/supervisor-userscript.conf" >> /app/supervisord.conf')
    os.system("supervisorctl reread && supervisorctl update")

    log("Installed as supervisor service: userscript-injector")


def list_scripts():
    """List all available scripts."""
    print("Built-in scripts:")
    for name, code in BUILTIN_SCRIPTS.items():
        desc = code.strip().split('\n')[0].replace('//', '').strip()
        print(f"  {name}: {desc}")

    print(f"\nCustom scripts in {SCRIPTS_DIR}:")
    for f in SCRIPTS_DIR.glob("*.js"):
        print(f"  {f.stem}: {f.name}")


def inject_custom_script(filepath):
    """Inject a custom script file into all current tabs."""
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found")
        return

    source = Path(filepath).read_text()
    name = Path(filepath).stem

    targets = get_targets()
    page_targets = [t for t in targets if t.get("type") == "page"]

    print(f"Injecting {name} into {len(page_targets)} tabs...")
    for target in page_targets:
        ws_url = target.get("webSocketDebuggerUrl")
        if ws_url:
            success = inject_script_into_tab(ws_url, name, source)
            print(f"  {'✓' if success else '✗'} {target.get('url', '')[:60]}")

    # Save to scripts dir for future tabs
    dest = SCRIPTS_DIR / f"{name}.js"
    dest.write_text(source)
    print(f"\nSaved to {dest} for future tabs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="TRAE Chrome Userscript Injector")
    parser.add_argument("--install", action="store_true", help="Install as supervisor service")
    parser.add_argument("--list", action="store_true", help="List available scripts")
    parser.add_argument("--inject", metavar="FILE", help="Inject a custom script file")
    parser.add_argument("--daemon", action="store_true", help="Run as daemon")

    args = parser.parse_args()

    if args.install:
        install_as_service()
    elif args.list:
        list_scripts()
    elif args.inject:
        inject_custom_script(args.inject)
    elif args.daemon:
        run_daemon()
    else:
        # Default: run as daemon
        run_daemon()
