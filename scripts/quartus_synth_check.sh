#!/usr/bin/env bash
# ============================================================================
# fabi386: Post-Feature Quartus Synthesis Check
# ============================================================================
# Converts SV to Verilog-2001 via sv2v, copies to the Quartus VM tmpfs
# ramdisk, and runs synthesis to extract resource numbers.
#
# Designed for Quartus 21.1 running under Rosetta in a UTM ARM64 VM.
#
# IMPORTANT: Uses --parallel=1 because Rosetta deadlocks on Quartus's
#            multi-process IPC (named pipes between master/helper processes).
#
# Prerequisites:
#   - sv2v installed locally (ARM, via Homebrew)
#   - Quartus VM running (UTM, Ubuntu ARM64 + Rosetta)
#   - sshpass installed: brew install hudochenkov/sshpass/sshpass
#   - Run from the fabi386 project root directory
#
# Usage:
#   ./scripts/quartus_synth_check.sh [VM_IP] [--full]
#
# Options:
#   VM_IP     VM IP address (default: auto-detect or 192.168.64.4)
#   --full    Run full compile (synthesis + fitter + timing). Slower.
#             Gives accurate Fmax and place-and-route results.
#   (default) Synthesis-only (~90 seconds). Gives ALM/M10K/DSP numbers.
# ============================================================================

set -euo pipefail

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# --- Configuration ---
VM_USER="quartus"
VM_PASS="quartus"
QUARTUS_BIN="\$HOME/intelFPGA_lite/21.1/quartus/bin"
PROJECT="f386_sv2v_fast"
BUILD_DIR="build"
SV2V_OUTPUT="${BUILD_DIR}/f386_sv2v_full.v"
VM_WORKDIR="/tmp/ramdisk"

SSH_OPTS="-o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=5"

# --- Parse args ---
VM_IP=""
FULL_COMPILE=0

for arg in "$@"; do
    case "$arg" in
        --full) FULL_COMPILE=1 ;;
        *) VM_IP="$arg" ;;
    esac
done

# Auto-detect VM IP if not provided
if [[ -z "$VM_IP" ]]; then
    VM_IP="192.168.64.4"
    warn "No VM IP specified, trying default $VM_IP"
fi

ssh_cmd() {
    sshpass -p "$VM_PASS" ssh $SSH_OPTS "$VM_USER@$VM_IP" "$@"
}

scp_cmd() {
    sshpass -p "$VM_PASS" scp $SSH_OPTS "$@"
}

# --- Check prerequisites ---
if ! command -v sv2v &>/dev/null; then
    fail "sv2v not found in PATH. Install: brew install sv2v"
    exit 1
fi

if ! command -v sshpass &>/dev/null; then
    fail "sshpass not found. Install: brew install hudochenkov/sshpass/sshpass"
    exit 1
fi

if [[ ! -f "rtl/top/f386_pkg.sv" ]]; then
    fail "Not in fabi386 project root (rtl/top/f386_pkg.sv not found)"
    exit 1
fi

# --- Step 1: sv2v conversion ---
info "Converting SystemVerilog to Verilog-2001 via sv2v..."
mkdir -p "$BUILD_DIR"
sv2v -I rtl/core \
    rtl/top/f386_pkg.sv \
    rtl/primitives/*.sv \
    rtl/core/*.sv \
    rtl/memory/*.sv \
    rtl/soc/*.sv \
    rtl/top/*.sv \
    > "$SV2V_OUTPUT" 2>&1

LINE_COUNT=$(wc -l < "$SV2V_OUTPUT")
ok "sv2v produced $LINE_COUNT lines → $SV2V_OUTPUT"

# --- Step 2: Test VM connectivity ---
info "Connecting to Quartus VM at $VM_IP..."
if ! ssh_cmd 'echo ok' &>/dev/null; then
    fail "Cannot reach VM at $VM_IP"
    echo "  Check the VM is running and get its IP: ip addr show enp0s1"
    exit 1
fi
ok "VM reachable"

# --- Step 3: Set up tmpfs ramdisk and copy files ---
info "Setting up tmpfs ramdisk on VM..."
ssh_cmd "
    if ! mountpoint -q $VM_WORKDIR 2>/dev/null; then
        mkdir -p $VM_WORKDIR
        echo '$VM_PASS' | sudo -S mount -t tmpfs -o size=2G tmpfs $VM_WORKDIR 2>/dev/null
        echo '$VM_PASS' | sudo -S chown $VM_USER:$VM_USER $VM_WORKDIR 2>/dev/null
    fi
    rm -rf $VM_WORKDIR/db $VM_WORKDIR/incremental_db $VM_WORKDIR/output_files $VM_WORKDIR/*.rpt 2>/dev/null
    echo 'ready'
"

info "Copying files to VM ramdisk..."
scp_cmd "$SV2V_OUTPUT" "$VM_USER@$VM_IP:$VM_WORKDIR/"
scp_cmd rtl/core/f386_alu.v "$VM_USER@$VM_IP:$VM_WORKDIR/"
scp_cmd rtl/core/f386_fpu_spatial.v "$VM_USER@$VM_IP:$VM_WORKDIR/"
scp_cmd f386.sdc "$VM_USER@$VM_IP:$VM_WORKDIR/"
scp_cmd f386_sv2v_fast.qsf "$VM_USER@$VM_IP:$VM_WORKDIR/"
scp_cmd f386_sv2v_fast.qpf "$VM_USER@$VM_IP:$VM_WORKDIR/"
ok "Files copied to $VM_WORKDIR"

# --- Step 4: Run synthesis ---
info "Running Analysis & Synthesis (--parallel=1 for Rosetta compatibility)..."
START=$(date +%s)

ssh_cmd "
    export PATH=$QUARTUS_BIN:\$PATH
    cd $VM_WORKDIR
    quartus_map --parallel=1 --read_settings_files=on --write_settings_files=off $PROJECT -c $PROJECT 2>&1
" > /tmp/fabi386_quartus.log 2>&1
MAP_EXIT=$?

END=$(date +%s)
ELAPSED=$((END - START))

if [[ $MAP_EXIT -ne 0 ]]; then
    fail "Synthesis failed (exit code $MAP_EXIT) in ${ELAPSED}s"
    echo "  Last 20 lines of output:"
    tail -20 /tmp/fabi386_quartus.log
    exit 1
fi

# Check for errors in log
ERROR_COUNT=$(grep -c "^Error" /tmp/fabi386_quartus.log || true)
if [[ $ERROR_COUNT -gt 0 ]]; then
    fail "Synthesis had $ERROR_COUNT error(s)"
    grep "^Error" /tmp/fabi386_quartus.log
    exit 1
fi

ok "Synthesis completed in ${ELAPSED} seconds"

# --- Step 5: Optionally run fitter + timing ---
if [[ $FULL_COMPILE -eq 1 ]]; then
    info "Running Fitter (--parallel=1)..."
    ssh_cmd "
        export PATH=$QUARTUS_BIN:\$PATH
        cd $VM_WORKDIR
        quartus_fit --parallel=1 $PROJECT -c $PROJECT 2>&1
    " >> /tmp/fabi386_quartus.log 2>&1

    info "Running Timing Analysis..."
    ssh_cmd "
        export PATH=$QUARTUS_BIN:\$PATH
        cd $VM_WORKDIR
        quartus_sta $PROJECT -c $PROJECT 2>&1
    " >> /tmp/fabi386_quartus.log 2>&1

    ok "Full compile completed"
fi

# --- Step 6: Fetch and parse report ---
MAP_RPT="/tmp/fabi386_map.rpt"
ssh_cmd "cat $VM_WORKDIR/$PROJECT.map.rpt 2>/dev/null" > "$MAP_RPT"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  fabi386 Quartus Synthesis Resource Report${NC}"
echo -e "${BOLD}  Device: Cyclone V 5CSEBA6U23I7 (DE10-Nano)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Extract resource summary table
if grep -q "Resource Usage Summary" "$MAP_RPT"; then
    # ALM estimate
    ALM_EST=$(grep "Estimate of Logic utilization" "$MAP_RPT" | grep -oP ';\s*\K[0-9,]+' | head -1 || true)
    ALUT_COUNT=$(grep "Combinational ALUT usage for logic" "$MAP_RPT" | grep -oP ';\s*\K[0-9,]+' | head -1 || true)
    REG_COUNT=$(grep "Dedicated logic registers" "$MAP_RPT" | grep -oP ';\s*\K[0-9,]+' | head -1 || true)
    MEM_BITS=$(grep "Total block memory bits" "$MAP_RPT" | grep -oP ';\s*\K[0-9,]+' | head -1 || true)
    DSP_COUNT=$(grep "Total DSP Blocks" "$MAP_RPT" | grep -oP ';\s*\K[0-9,]+' | head -1 || true)

    printf "  %-30s %s / 41,910\n" "ALMs (estimated):" "${ALM_EST:-?}"
    printf "  %-30s %s\n" "Combinational ALUTs:" "${ALUT_COUNT:-?}"
    printf "  %-30s %s\n" "Dedicated Registers:" "${REG_COUNT:-?}"
    printf "  %-30s %s\n" "Block Memory Bits:" "${MEM_BITS:-?}"
    printf "  %-30s %s / 112\n" "DSP Blocks:" "${DSP_COUNT:-?}"
else
    warn "Could not parse resource summary from report"
    grep -i "logic\|ALM\|register\|memory\|DSP" "$MAP_RPT" | head -10
fi

echo ""

# Per-entity breakdown (top modules)
if grep -q "Compilation Hierarchy Node" "$MAP_RPT"; then
    echo -e "${BOLD}  Per-Module Breakdown (ALUTs / Regs):${NC}"
    # Extract entity rows, skip header lines
    grep -E "^\;" "$MAP_RPT" | grep -E "(f386_|alu_)" | head -25 | while IFS=';' read -r _ name aluts regs mem dsp _ ; do
        name=$(echo "$name" | sed 's/|//g; s/^ *//; s/ *$//')
        aluts=$(echo "$aluts" | sed 's/^ *//; s/ *$//')
        regs=$(echo "$regs" | sed 's/^ *//; s/ *$//')
        if [[ -n "$name" && -n "$aluts" ]]; then
            printf "    %-45s %6s / %s\n" "$name" "$aluts" "$regs"
        fi
    done
    echo ""
fi

# Fmax if full compile
if [[ $FULL_COMPILE -eq 1 ]]; then
    STA_RPT="/tmp/fabi386_sta.rpt"
    ssh_cmd "cat $VM_WORKDIR/$PROJECT.sta.rpt 2>/dev/null" > "$STA_RPT" 2>/dev/null || true
    if [[ -f "$STA_RPT" ]]; then
        FMAX_LINE=$(grep -i "Fmax" "$STA_RPT" | head -1 || true)
        if [[ -n "$FMAX_LINE" ]]; then
            echo "  $FMAX_LINE"
            echo ""
        fi
    fi
fi

# --- Step 7: Append to synthesis history log ---
HISTORY_LOG="docs/synthesis_history.csv"

if [[ ! -d "docs" ]]; then
    mkdir -p docs
fi

if [[ ! -f "$HISTORY_LOG" ]]; then
    echo "date,phase,alms,regs,dsp,block_mem_bits,elapsed_sec,notes" > "$HISTORY_LOG"
fi

DATE=$(date +%Y-%m-%d)
echo "${DATE},,${ALM_EST:-?},${REG_COUNT:-?},${DSP_COUNT:-?},${MEM_BITS:-?},${ELAPSED},quartus_synth_check" >> "$HISTORY_LOG"
info "Appended to ${HISTORY_LOG}"

echo ""
info "Full log: /tmp/fabi386_quartus.log"
info "Full report: $MAP_RPT"
