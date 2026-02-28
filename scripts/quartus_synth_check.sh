#!/usr/bin/env bash
# ============================================================================
# fabi386: Post-Feature Quartus Synthesis Check
# ============================================================================
# Runs synthesis-only (Analysis & Synthesis) and extracts resource numbers.
# Use this after each feature implementation to track FPGA utilization.
#
# Prerequisites:
#   - Quartus Prime (Lite or Standard) installed and in PATH
#   - Run from the fabi386 project root directory
#
# Usage:
#   ./scripts/quartus_synth_check.sh [--full]
#
# Options:
#   --full    Run full compile (synthesis + fitter + timing). Slower (~15 min)
#             but gives accurate Fmax and place-and-route results.
#   (default) Synthesis-only (~2-4 min). Gives ALM/M10K/DSP numbers.
# ============================================================================

set -euo pipefail

PROJECT="f386"
REPORT_DIR="output_files"

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

# Check prerequisites
if ! command -v quartus_map &>/dev/null; then
    fail "quartus_map not found in PATH"
    echo "  Install Quartus Prime or add it to your PATH:"
    echo "  export PATH=\$PATH:/path/to/quartus/bin"
    exit 1
fi

if [[ ! -f "${PROJECT}.qpf" ]]; then
    fail "Not in fabi386 project root (${PROJECT}.qpf not found)"
    exit 1
fi

# Parse args
FULL_COMPILE=0
if [[ "${1:-}" == "--full" ]]; then
    FULL_COMPILE=1
fi

# Step 1: Run synthesis
info "Running Analysis & Synthesis..."
START=$(date +%s)
quartus_map "${PROJECT}" --read_settings_files=on 2>&1 | tail -5
MAP_EXIT=$?
END=$(date +%s)

if [[ $MAP_EXIT -ne 0 ]]; then
    fail "Synthesis failed (exit code $MAP_EXIT)"
    echo "  Check ${REPORT_DIR}/${PROJECT}.map.rpt for details"
    exit 1
fi
ok "Synthesis completed in $((END - START)) seconds"

# Step 2: Optionally run fitter + timing
if [[ $FULL_COMPILE -eq 1 ]]; then
    info "Running Fitter..."
    quartus_fit "${PROJECT}" 2>&1 | tail -3

    info "Running Timing Analysis..."
    quartus_sta "${PROJECT}" 2>&1 | tail -3

    ok "Full compile completed"
fi

# Step 3: Extract resource numbers from map report
MAP_RPT="${REPORT_DIR}/${PROJECT}.map.rpt"

if [[ ! -f "$MAP_RPT" ]]; then
    fail "Map report not found at $MAP_RPT"
    exit 1
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  fabi386 Synthesis Resource Report${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""

# ALM usage
ALM_LINE=$(grep -i "Total ALMs" "$MAP_RPT" | head -1 || true)
if [[ -n "$ALM_LINE" ]]; then
    echo "  $ALM_LINE"
fi

# Logic utilization
grep -i "Combinational ALUTs" "$MAP_RPT" | head -1 || true
grep -i "Dedicated logic registers" "$MAP_RPT" | head -1 || true

# Memory
M10K_LINE=$(grep -i "Total block memory bits" "$MAP_RPT" | head -1 || true)
if [[ -z "$M10K_LINE" ]]; then
    M10K_LINE=$(grep -i "M10K" "$MAP_RPT" | head -1 || true)
fi
if [[ -n "$M10K_LINE" ]]; then
    echo "  $M10K_LINE"
fi

# DSP
DSP_LINE=$(grep -i "Total DSP" "$MAP_RPT" | head -1 || true)
if [[ -n "$DSP_LINE" ]]; then
    echo "  $DSP_LINE"
fi

echo ""

# Step 4: Extract Fmax if full compile was run
if [[ $FULL_COMPILE -eq 1 ]]; then
    STA_RPT="${REPORT_DIR}/${PROJECT}.sta.rpt"
    if [[ -f "$STA_RPT" ]]; then
        FMAX_LINE=$(grep -i "Fmax" "$STA_RPT" | head -1 || true)
        if [[ -n "$FMAX_LINE" ]]; then
            echo "  $FMAX_LINE"
            echo ""
        fi
    fi
fi

# Step 5: Append to synthesis history log
HISTORY_LOG="docs/synthesis_history.csv"
DATE=$(date +%Y-%m-%d)

if [[ ! -f "$HISTORY_LOG" ]]; then
    echo "date,phase,alms,m10k,dsp,fmax_mhz,notes" > "$HISTORY_LOG"
fi

# Try to parse ALM count from report
ALM_COUNT=$(grep -oP 'Total ALMs\s*;\s*\K[\d,]+' "$MAP_RPT" 2>/dev/null | tr -d ',' || echo "?")
M10K_COUNT=$(grep -oP 'M10K blocks\s*;\s*\K[\d,]+' "$MAP_RPT" 2>/dev/null | tr -d ',' || echo "?")
DSP_COUNT=$(grep -oP 'Total DSP Blocks\s*;\s*\K[\d,]+' "$MAP_RPT" 2>/dev/null | tr -d ',' || echo "?")

echo "${DATE},P1.8b,${ALM_COUNT},${M10K_COUNT},${DSP_COUNT},,post-feature check" >> "$HISTORY_LOG"
info "Appended to ${HISTORY_LOG}"

echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Update docs/fpga_resource_budget.md Synthesis History table"
echo "  2. If ALM utilization > 70%, review feature gate status"
echo "  3. If M10K > 400, consider moving small RAMs to MLABs"
echo ""
