#!/bin/bash
# ===================================================================
# 沙箱负载检测脚本 v2
# 优先使用宝塔面板 Python API 获取负载数据（更准确）
# 回退到 /proc 原始数据（宝塔不可用时）
# 返回 JSON 格式的负载状态和建议
#
# 强制执行标签：[FORCE] 或 [F]
# ===================================================================

# 检查 /www 软链接
if [ ! -d "/www/server/panel" ]; then
    if [ -d "/workspace/www/server/panel" ]; then
        ln -sf /workspace/www /www 2>/dev/null
    else
        # 宝塔不可用，回退到 /proc
        BT_PYTHON=""
    fi
fi

BT_PYTHON="/www/server/panel/pyenv/bin/python3"
FORCE_TAG_FORCE="[FORCE]"
FORCE_TAG_F="[F]"

if [ -x "$BT_PYTHON" ] && [ -d "/www/server/panel" ]; then
    # 使用宝塔 Python API 获取负载数据
    RESULT=$($BT_PYTHON -c "
import sys, json
sys.path.insert(0, '/www/server/panel')
sys.path.insert(0, '/www/server/panel/class')

try:
    import system
    s = system.system()

    # 获取负载
    load = s.GetLoadAverage(True)
    load_1min = load['one']
    load_5min = load['five']
    load_15min = load['fifteen']
    load_safe = load['safe']
    load_limit = load['limit']

    # 获取内存
    mem = s.GetMemInfo()
    mem_total = mem['memTotal']
    mem_used = mem['memRealUsed']
    mem_avail = mem['memAvailable']
    mem_pct = round(mem_used / mem_total * 100, 1)

    # 获取CPU
    cpu = s.GetCpuInfo()
    cpu_percent = cpu[0]
    cpu_cores = cpu[1]

    # 获取磁盘
    import os
    disk_total = os.statvfs('/workspace').f_blocks * os.statvfs('/workspace').f_frsize
    disk_free = os.statvfs('/workspace').f_bavail * os.statvfs('/workspace').f_frsize
    disk_used = disk_total - disk_free
    disk_pct = round(disk_used / disk_total * 100, 1)

    # 计算阈值（基于宝塔的 safe/limit）
    # safe = cores * 1.5, limit = cores * 2
    load_warn = round(load_safe * 0.53, 1)   # ~80% of cores
    load_critical = round(load_safe * 0.6, 1) # ~90% of cores

    # 判断负载等级
    level = 'safe'
    skip_reason = ''

    if load_1min > load_critical or mem_pct > 85 or disk_pct > 90:
        level = 'critical'
        reasons = []
        if load_1min > load_critical:
            reasons.append(f'CPU负载 {load_1min:.2f} 超过临界值 {load_critical}')
        if mem_pct > 85:
            reasons.append(f'内存 {mem_pct}% 超过临界值 85%')
        if disk_pct > 90:
            reasons.append(f'磁盘 {disk_pct}% 超过临界值 90%')
        skip_reason = '; '.join(reasons)
    elif load_1min > load_warn or mem_pct > 75 or disk_pct > 80:
        level = 'warn'
        reasons = []
        if load_1min > load_warn:
            reasons.append(f'CPU负载 {load_1min:.2f} 接近上限 {load_warn}')
        if mem_pct > 75:
            reasons.append(f'内存 {mem_pct}% 接近上限 75%')
        if disk_pct > 80:
            reasons.append(f'磁盘 {disk_pct}% 接近上限 80%')
        skip_reason = '; '.join(reasons)

    output = {
        'source': 'bt-panel-api',
        'level': level,
        'can_run_heavy_tasks': level == 'safe',
        'skip_reason': skip_reason if skip_reason else '无',
        'metrics': {
            'cpu_cores': cpu_cores,
            'cpu_usage_pct': cpu_percent,
            'load_1min': round(load_1min, 3),
            'load_5min': round(load_5min, 3),
            'load_15min': round(load_15min, 3),
            'load_warn_threshold': load_warn,
            'load_critical_threshold': load_critical,
            'bt_load_safe': load_safe,
            'bt_load_limit': load_limit,
            'mem_total_mb': mem_total,
            'mem_used_mb': mem_used,
            'mem_avail_mb': mem_avail,
            'mem_usage_pct': mem_pct,
            'disk_total_gb': round(disk_total / 1024**3, 1),
            'disk_used_gb': round(disk_used / 1024**3, 1),
            'disk_usage_pct': disk_pct,
        },
        'force_tags': ['[FORCE]', '[F]'],
        'hint': '用户消息中包含 [FORCE] 或 [F] 可跳过负载检查强制执行'
    }
    print(json.dumps(output, ensure_ascii=False))
except Exception as e:
    # 回退标记
    print(json.dumps({'source': 'error', 'error': str(e)}, ensure_ascii=False))
" 2>/dev/null)

    if [ -n "$RESULT" ] && echo "$RESULT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "$RESULT"
        exit 0
    fi
fi

# 回退方案：直接读 /proc
CPU_CORES=$(nproc)
LOAD_WARN=$(awk "BEGIN {printf \"%.1f\", ${CPU_CORES} * 0.8}")
LOAD_CRITICAL=$(awk "BEGIN {printf \"%.1f\", ${CPU_CORES} * 0.9}")

LOAD_1MIN=$(cat /proc/loadavg | awk '{print $1}')
LOAD_5MIN=$(cat /proc/loadavg | awk '{print $2}')
LOAD_15MIN=$(cat /proc/loadavg | awk '{print $3}')

MEM_TOTAL=$(free | awk 'NR==2{print $2}')
MEM_USED=$(free | awk 'NR==2{print $3}')
MEM_AVAIL=$(free | awk 'NR==2{print $7}')
MEM_PCT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED / $MEM_TOTAL) * 100}")

DISK_PCT=$(df /workspace | tail -1 | awk '{print $5}' | tr -d '%')

LEVEL="safe"
SKIP_REASON=""

if (( $(awk "BEGIN {print ($LOAD_1MIN > $LOAD_CRITICAL)}") )); then
    LEVEL="critical"
    SKIP_REASON="CPU负载 ${LOAD_1MIN} 超过临界值 ${LOAD_CRITICAL}"
elif (( $(awk "BEGIN {print ($LOAD_1MIN > $LOAD_WARN)}") )); then
    LEVEL="warn"
    SKIP_REASON="CPU负载 ${LOAD_1MIN} 接近上限 ${LOAD_WARN}"
fi

if (( $(awk "BEGIN {print ($MEM_PCT > 85)}") )); then
    LEVEL="critical"
    [ -n "$SKIP_REASON" ] && SKIP_REASON="$SKIP_REASON; "
    SKIP_REASON="${SKIP_REASON}内存 ${MEM_PCT}% 超过临界值 85%"
elif (( $(awk "BEGIN {print ($MEM_PCT > 75)}") )); then
    [ "$LEVEL" = "safe" ] && LEVEL="warn"
    [ -n "$SKIP_REASON" ] && SKIP_REASON="$SKIP_REASON; "
    SKIP_REASON="${SKIP_REASON}内存 ${MEM_PCT}% 接近上限 75%"
fi

if (( DISK_PCT > 90 )); then
    LEVEL="critical"
    [ -n "$SKIP_REASON" ] && SKIP_REASON="$SKIP_REASON; "
    SKIP_REASON="${SKIP_REASON}磁盘 ${DISK_PCT}% 超过临界值 90%"
elif (( DISK_PCT > 80 )); then
    [ "$LEVEL" = "safe" ] && LEVEL="warn"
    [ -n "$SKIP_REASON" ] && SKIP_REASON="$SKIP_REASON; "
    SKIP_REASON="${SKIP_REASON}磁盘 ${DISK_PCT}% 接近上限 80%"
fi

cat << EOF
{
    "source": "proc-fallback",
    "level": "${LEVEL}",
    "can_run_heavy_tasks": $([ "$LEVEL" = "safe" ] && echo "true" || echo "false"),
    "skip_reason": "${SKIP_REASON:-无}",
    "metrics": {
        "cpu_cores": ${CPU_CORES},
        "load_1min": ${LOAD_1MIN},
        "load_5min": ${LOAD_5MIN},
        "load_15min": ${LOAD_15MIN},
        "load_warn_threshold": ${LOAD_WARN},
        "load_critical_threshold": ${LOAD_CRITICAL},
        "mem_total_mb": $((MEM_TOTAL / 1024)),
        "mem_used_mb": $((MEM_USED / 1024)),
        "mem_avail_mb": $((MEM_AVAIL / 1024)),
        "mem_usage_pct": ${MEM_PCT},
        "disk_usage_pct": ${DISK_PCT}
    },
    "force_tags": ["[FORCE]", "[F]"],
    "hint": "用户消息中包含 [FORCE] 或 [F] 可跳过负载检查强制执行"
}
EOF
