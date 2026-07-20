#!/bin/bash
# ==========================================
# Safe Cleanup Script
# Cleans logs, caches, and temporary files
# 100% safe - never deletes system files or important data
#
# Usage: bash cleanup.sh
# ==========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
source "$MODULES_DIR/config.sh"
source "$MODULES_DIR/utils.sh"

WORKSPACE="/home/user/.super_doubao/super-doubao-runtime/workspace"
DOWNLOADS_DIR="$WORKSPACE/Downloads"

echo "=========================================="
echo "  Safe Cleanup Script"
echo "=========================================="
echo ""

freed=0

# ==========================================
# 1. Clean log files in workspace
# ==========================================
log_info "Cleaning log files..."

# Logs in home directory (non-persistent)
log_count=0
for log in /home/user/*.log /home/user/recovery.log; do
    if [ -f "$log" ]; then
        size=$(stat -c%s "$log" 2>/dev/null || echo 0)
        rm -f "$log"
        freed=$((freed + size))
        log_count=$((log_count + 1))
    fi
done

# Logs in workspace root (keep reset tracker logs - they're important)
# Only clean temporary logs, not the important ones
for log in "$WORKSPACE"/*.log; do
    # Skip important tracker logs
    case "$(basename "$log")" in
        sandbox-tracker-heartbeat.log) continue ;;
    esac
    if [ -f "$log" ]; then
        size=$(stat -c%s "$log" 2>/dev/null || echo 0)
        rm -f "$log"
        freed=$((freed + size))
        log_count=$((log_count + 1))
    fi
done

if [ "$log_count" -gt 0 ]; then
    log_ok "Removed $log_count log file(s)"
else
    log_skip "No log files to clean"
fi

# ==========================================
# 2. Clean Python cache files
# ==========================================
log_info "Cleaning Python caches..."

pycache_count=0
# Find __pycache__ directories and .pyc files in workspace (but not in skills)
find "$WORKSPACE" -path "*/skills/*" -prune -o \
    -type d -name "__pycache__" -print0 2>/dev/null | while IFS= read -r -d '' dir; do
    size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    rm -rf "$dir"
    freed=$((freed + size))
    pycache_count=$((pycache_count + 1))
done

# Also clean .pyc files
find "$WORKSPACE" -path "*/skills/*" -prune -o \
    -type f -name "*.pyc" -print0 2>/dev/null | while IFS= read -r -d '' file; do
    size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    rm -f "$file"
    freed=$((freed + size))
done

log_ok "Cleaned Python caches"

# ==========================================
# 3. Clean temporary files
# ==========================================
log_info "Cleaning temporary files..."

# .tmp files in workspace
tmp_count=0
find "$WORKSPACE" -maxdepth 3 -type f -name "*.tmp" -delete 2>/dev/null
find "$WORKSPACE" -maxdepth 3 -type f -name "*.temp" -delete 2>/dev/null
find "$WORKSPACE" -maxdepth 3 -type f -name "*~" -delete 2>/dev/null
find "$WORKSPACE" -maxdepth 3 -type f -name ".DS_Store" -delete 2>/dev/null

log_ok "Cleaned temporary files"

# ==========================================
# 4. Downloads directory - report only
# ==========================================
log_info "Checking Downloads directory..."

if [ -d "$DOWNLOADS_DIR" ] && [ "$(ls -A "$DOWNLOADS_DIR" 2>/dev/null)" ]; then
    echo ""
    echo "=== Downloads Directory Contents ==="
    echo "Path: $DOWNLOADS_DIR"
    echo ""
    total_size=0
    while IFS= read -r -d '' file; do
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        total_size=$((total_size + size))
        size_h=$(du -h "$file" 2>/dev/null | awk '{print $1}')
        echo "  [$size_h] $(basename "$file")"
    done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
    echo ""
    echo "Total: $(du -sh "$DOWNLOADS_DIR" 2>/dev/null | awk '{print $1}')"
    echo ""
    echo "NOTE: Download files are NOT deleted automatically."
    echo "Ask the user which files to delete."
    echo ""
else
    log_skip "Downloads directory is empty or doesn't exist"
fi

# ==========================================
# 6. Apt cache cleanup (safe, just cache)
# ==========================================
log_info "Cleaning apt cache..."

if [ "$(id -u)" = "0" ]; then
    apt-get clean 2>/dev/null
    log_ok "Apt cache cleaned"
else
    log_skip "Not root - skipping apt clean"
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "  Cleanup Complete"
echo "=========================================="
echo ""

# Convert to human readable
if [ "$freed" -ge 1048576 ]; then
    freed_h=$(echo "scale=2; $freed / 1048576" | bc 2>/dev/null || echo "0")
    echo "Freed: ~${freed_h} MB"
elif [ "$freed" -ge 1024 ]; then
    freed_h=$(echo "scale=2; $freed / 1024" | bc 2>/dev/null || echo "0")
    echo "Freed: ~${freed_h} KB"
else
    echo "Freed: ~${freed} bytes"
fi

echo ""
echo "Safe-cleaned items:"
echo "  - Log files (home + workspace)"
echo "  - Python __pycache__ and .pyc files"
echo "  - Temporary files (*.tmp, *.temp, *~, .DS_Store)"
echo "  - Apt cache (if root)"
echo ""
echo "Preserved (never deleted):"
echo "  - All system files and dependencies"
echo "  - Skills directory"
echo "  - doubao_work/ scripts and data"
echo "  - memory.md and important docs"
echo "  - Sandbox reset tracker logs"
echo "  - Downloads (ask user before deleting)"
echo ""
