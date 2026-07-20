#!/bin/bash
# ==========================================
# Sandbox Deployment Package Builder
# Packages entire doubao_work directory with maximum compression
#
# Usage: bash package_deployment.sh
# Output: workspace/doubao-sandbox-deploy.tar.gz
# Compression: Maximum (gzip -9), best ratio, slowest speed
# ==========================================
set -e

# Get script directory (doubao_work/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Output file location (workspace directory)
OUTPUT_FILE="$(dirname "$SCRIPT_DIR")/doubao-sandbox-deploy.tar.gz"

echo "=========================================="
echo "  Sandbox Deployment Package Builder"
echo "  Maximum Compression Mode"
echo "=========================================="
echo ""
echo "Source:  $SCRIPT_DIR"
echo "Output:  $OUTPUT_FILE"
echo ""

echo "[*] Creating package with maximum compression..."

# Create tar.gz with maximum compression (gzip -9)
# -C changes to source dir, so paths are relative (no top-level dir wrapper)
cd "$SCRIPT_DIR"
tar -cf - . | gzip -9 > "$OUTPUT_FILE"

# Verify package
if [ -f "$OUTPUT_FILE" ]; then
    PACKAGE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    FILE_COUNT=$(tar -tzf "$OUTPUT_FILE" | wc -l)
    echo ""
    echo "[OK] Package created successfully!"
    echo "     File:  $OUTPUT_FILE"
    echo "     Size:  $PACKAGE_SIZE"
    echo "     Files: $FILE_COUNT"
    echo ""
    echo "[*] Package contents (first 20):"
    tar -tzf "$OUTPUT_FILE" | head -20
    echo "     ..."
    echo ""
    echo "=========================================="
    echo "  Done!"
    echo "=========================================="
    echo ""
    echo "To deploy on a new sandbox:"
    echo "  1. Upload doubao-sandbox-deploy.tar.gz to workspace/"
    echo "  2. mkdir -p doubao_work && cd doubao_work"
    echo "  3. tar -xzf ../doubao-sandbox-deploy.tar.gz"
    echo "  4. bash scripts/recover_all.sh"
    echo "  5. Wait 30-45 seconds (v4 optimized)"
    echo "  6. bash scripts/recover_all.sh"
    echo ""
else
    echo "[ERROR] Failed to create package"
    exit 1
fi
