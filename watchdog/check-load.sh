#!/bin/bash
# ===================================================================
# 沙箱负载检测脚本
# AI 在执行重负载任务前应调用此脚本检查系统资源
# 返回 JSON 格式的负载状态和建议
# ===================================================================

# 阈值配置（使用 awk 计算浮点数）
CPU_CORES=$(nproc)
LOAD_WARN=$(awk "BEGIN {printf \"%.1f\", ${CPU_CORES} * 0.8}")
LOAD_CRITICAL=$(awk "BEGIN {printf \"%.1f\", ${CPU_CORES} * 0.9}")
MEM_WARN=75    # 75% memory usage
MEM_CRITICAL=85 # 85% memory usage
DISK_WARN=80    # 80% disk usage
DISK_CRITICAL=90 # 90% disk usage

# 获取负载
LOAD_1MIN=$(cat /proc/loadavg | awk '{print $1}')
LOAD_5MIN=$(cat /proc/loadavg | awk '{print $2}')
LOAD_15MIN=$(cat /proc/loadavg | awk '{print $3}')

# 获取内存使用率
MEM_TOTAL=$(free | awk 'NR==2{print $2}')
MEM_USED=$(free | awk 'NR==2{print $3}')
MEM_AVAIL=$(free | awk 'NR==2{print $7}')
MEM_PCT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED / $MEM_TOTAL) * 100}")

# 获取磁盘使用率
DISK_PCT=$(df /workspace | tail -1 | awk '{print $5}' | tr -d '%')

# 获取进程数
PROC_COUNT=$(ps aux | wc -l)

# 获取占用最高的进程
TOP_PROC=$(ps aux --sort=-%cpu | head -2 | tail -1 | awk '{printf "%s(CPU:%s%%,MEM:%s%%)", $11, $3, $4}')

# 判断负载等级
LEVEL="safe"
SKIP_REASON=""

# CPU负载检查
if (( $(awk "BEGIN {print ($LOAD_1MIN > $LOAD_CRITICAL)}") )); then
    LEVEL="critical"
    SKIP_REASON="CPU负载 ${LOAD_1MIN} 超过临界值 ${LOAD_CRITICAL}"
elif (( $(awk "BEGIN {print ($LOAD_1MIN > $LOAD_WARN)}") )); then
    LEVEL="warn"
    SKIP_REASON="CPU负载 ${LOAD_1MIN} 接近上限 ${LOAD_WARN}"
fi

# 内存检查
if (( $(awk "BEGIN {print ($MEM_PCT > $MEM_CRITICAL)}") )); then
    LEVEL="critical"
    [ -n "$SKIP_REASON" ] && SKIP_REASON="$SKIP_REASON; "
    SKIP_REASON="${SKIP_REASON}内存 ${MEM_PCT}% 超过临界值 ${MEM_CRITICAL}%"
elif (( $(awk "BEGIN {print ($MEM_PCT > $MEM_WARN)}") )); then
    [ "$LEVEL" = "safe" ] && LEVEL="warn"
    [ -n "$SKIP_REASON" ] && SKIP_REASON="$SKIP_REASON; "
    SKIP_REASON="${SKIP_REASON}内存 ${MEM_PCT}% 接近上限 ${MEM_WARN}%"
fi

# 磁盘检查
if (( DISK_PCT > DISK_CRITICAL )); then
    LEVEL="critical"
    [ -n "$SKIP_REASON" ] && SKIP_REASON="$SKIP_REASON; "
    SKIP_REASON="${SKIP_REASON}磁盘 ${DISK_PCT}% 超过临界值 ${DISK_CRITICAL}%"
elif (( DISK_PCT > DISK_WARN )); then
    [ "$LEVEL" = "safe" ] && LEVEL="warn"
    [ -n "$SKIP_REASON" ] && SKIP_REASON="$SKIP_REASON; "
    SKIP_REASON="${SKIP_REASON}磁盘 ${DISK_PCT}% 接近上限 ${DISK_WARN}%"
fi

# 输出 JSON
cat << EOF
{
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
        "mem_warn_threshold": ${MEM_WARN},
        "mem_critical_threshold": ${MEM_CRITICAL},
        "disk_usage_pct": ${DISK_PCT},
        "disk_warn_threshold": ${DISK_WARN},
        "disk_critical_threshold": ${DISK_CRITICAL},
        "process_count": ${PROC_COUNT}
    },
    "top_process": "${TOP_PROC}",
    "force_tag": "[FORCE]",
    "hint": "如果用户消息中包含 [FORCE] 标签，则跳过负载检查强制执行"
}
EOF
