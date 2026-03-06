#!/usr/bin/env bash
# ============================================================================
# fabi386: Quartus Synthesis Check
# ============================================================================
# Generic Quartus wrapper:
#   1. Converts SV to Verilog-2001 via sv2v
#   2. Stages a self-contained Quartus job directory locally
#   3. Dispatches the job to a selected remote backend (VM or NAS)
#   4. Fetches reports/artifacts and prints a resource summary
#
# Backward-compatible usage:
#   ./scripts/quartus_synth_check.sh <host> [--full]
#
# Preferred usage:
#   ./scripts/quartus_synth_check.sh --backend nas --host 192.168.50.100
#   ./scripts/quartus_synth_check.sh --backend vm  --host 192.168.64.4 --full
# ============================================================================

set -euo pipefail

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

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/quartus_synth_check.sh <host> [--full]
  ./scripts/quartus_synth_check.sh --backend <vm|nas> --host <host> [--full]

Options:
  --backend <vm|nas>   Select Quartus backend. Default: vm
  --host <host>        Backend host / IP address
  --pkg <path>         Override pkg file for sv2v (for temp-gated builds)
  --full               Run fitter + timing after synthesis
  --job-name <name>    Override generated local job directory name
  -h, --help           Show this help

Environment overrides:
  QUARTUS_BACKEND      Default backend if --backend is omitted
  QUARTUS_HOST         Default host if --host is omitted
  QUARTUS_PKG          Default pkg override if --pkg is omitted
  QUARTUS_PARALLEL     Quartus --parallel value. Default: auto
                       auto => VM backend uses 1, NAS backend uses remote CPU count

Examples:
  ./scripts/quartus_synth_check.sh 192.168.64.4
  ./scripts/quartus_synth_check.sh --backend nas --host 192.168.50.100 --pkg /tmp/f386_pkg_gate_on.sv
  ./scripts/quartus_synth_check.sh --backend nas --host 192.168.50.100 --full
USAGE
}

extract_summary_value() {
    local pattern="$1"
    local file="$2"
    # Quartus report format: ; field_name ; value ;
    # $1=empty, $2=field name, $3=value
    awk -F ';' -v pat="$pattern" '
        $0 ~ pat {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
            print $3
            exit
        }
    ' "$file"
}

PROJECT="${QUARTUS_PROJECT:-f386_sv2v_fast}"
BUILD_ROOT="build/quartus_jobs"
HISTORY_LOG="docs/synthesis_history.csv"
DEFAULT_VM_HOST="192.168.64.4"
BACKEND="${QUARTUS_BACKEND:-vm}"
HOST="${QUARTUS_HOST:-}"
FULL_COMPILE=0
JOB_NAME=""
POSITIONAL_HOST=""
PARALLEL="${QUARTUS_PARALLEL:-auto}"
PKG_FILE="${QUARTUS_PKG:-rtl/top/f386_pkg.sv}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)
            BACKEND="$2"
            shift 2
            ;;
        --backend=*)
            BACKEND="${1#*=}"
            shift
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --host=*)
            HOST="${1#*=}"
            shift
            ;;
        --pkg)
            PKG_FILE="$2"
            shift 2
            ;;
        --pkg=*)
            PKG_FILE="${1#*=}"
            shift
            ;;
        --full)
            FULL_COMPILE=1
            shift
            ;;
        --job-name)
            JOB_NAME="$2"
            shift 2
            ;;
        --job-name=*)
            JOB_NAME="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            fail "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -z "$POSITIONAL_HOST" ]]; then
                POSITIONAL_HOST="$1"
            else
                fail "Unexpected positional argument: $1"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$HOST" && -n "$POSITIONAL_HOST" ]]; then
    HOST="$POSITIONAL_HOST"
fi

case "$BACKEND" in
    vm|nas) ;;
    *)
        fail "Unsupported backend '$BACKEND'"
        usage
        exit 1
        ;;
esac

if [[ -z "$HOST" ]]; then
    if [[ "$BACKEND" == "vm" ]]; then
        HOST="$DEFAULT_VM_HOST"
        warn "No host specified, defaulting to VM host $HOST"
    else
        fail "--host is required for NAS backend"
        exit 1
    fi
fi

if [[ "$PARALLEL" != "auto" && ! "$PARALLEL" =~ ^[0-9]+$ ]]; then
    fail "QUARTUS_PARALLEL must be an integer or 'auto' (got '$PARALLEL')"
    exit 1
fi

if ! command -v sv2v >/dev/null 2>&1; then
    fail "sv2v not found in PATH"
    exit 1
fi

if [[ ! -f "rtl/top/f386_pkg.sv" ]]; then
    fail "Not in fabi386 project root (rtl/top/f386_pkg.sv not found)"
    exit 1
fi

if [[ ! -f "$PKG_FILE" ]]; then
    fail "pkg file not found: $PKG_FILE"
    exit 1
fi

mkdir -p "$BUILD_ROOT"

GIT_SHORT="nogit"
if command -v git >/dev/null 2>&1; then
    GIT_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [[ -n "$JOB_NAME" ]]; then
    JOB_ID=$(printf '%s' "$JOB_NAME" | tr -cs 'A-Za-z0-9._-' '_')
else
    JOB_ID="${TIMESTAMP}_${GIT_SHORT}_${BACKEND}"
fi

LOCAL_JOB_DIR="$BUILD_ROOT/$JOB_ID"
if [[ -e "$LOCAL_JOB_DIR" ]]; then
    fail "Local Quartus job dir already exists: $LOCAL_JOB_DIR"
    exit 1
fi

mkdir -p "$LOCAL_JOB_DIR/build" "$LOCAL_JOB_DIR/rtl/core"
SV2V_OUTPUT="$LOCAL_JOB_DIR/build/f386_sv2v_full.v"
SV2V_LOG="$LOCAL_JOB_DIR/sv2v.log"
LOCAL_LOG="$LOCAL_JOB_DIR/quartus.log"

info "Preparing Quartus job $JOB_ID (backend=$BACKEND, host=$HOST)"
info "Running sv2v..."
mapfile -t top_files < <(find rtl/top -maxdepth 1 -name '*.sv' ! -name 'f386_pkg.sv' | sort)

if ! sv2v -DSYNTHESIS -I rtl/core \
    "$PKG_FILE" \
    rtl/primitives/*.sv \
    rtl/core/*.sv \
    rtl/memory/*.sv \
    rtl/soc/*.sv \
    "${top_files[@]}" \
    > "$SV2V_OUTPUT" 2> "$SV2V_LOG"; then
    fail "sv2v failed"
    tail -20 "$SV2V_LOG" || true
    exit 1
fi

cp rtl/core/f386_alu.v "$LOCAL_JOB_DIR/rtl/core/"
cp rtl/core/f386_fpu_spatial.v "$LOCAL_JOB_DIR/rtl/core/"
cp f386.sdc "$LOCAL_JOB_DIR/"
cp "${PROJECT}.qsf" "$LOCAL_JOB_DIR/"
cp "${PROJECT}.qpf" "$LOCAL_JOB_DIR/"

LINE_COUNT=$(wc -l < "$SV2V_OUTPUT")
ok "sv2v produced $LINE_COUNT lines → $SV2V_OUTPUT"

cat > "$LOCAL_JOB_DIR/manifest.txt" <<MANIFEST
job_id=$JOB_ID
backend=$BACKEND
host=$HOST
project=$PROJECT
full_compile=$FULL_COMPILE
git_rev=$GIT_SHORT
parallel=$PARALLEL
pkg_file=$PKG_FILE
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
local_job_dir=$LOCAL_JOB_DIR
MANIFEST

: > "$LOCAL_LOG"

export QUARTUS_HOST="$HOST"
export QUARTUS_PROJECT="$PROJECT"
export QUARTUS_LOCAL_JOB_DIR="$LOCAL_JOB_DIR"
export QUARTUS_LOCAL_LOG="$LOCAL_LOG"
export QUARTUS_FULL_COMPILE="$FULL_COMPILE"
export QUARTUS_JOB_ID="$JOB_ID"
export QUARTUS_PARALLEL="$PARALLEL"

case "$BACKEND" in
    vm)  BACKEND_SCRIPT="./scripts/quartus_backend_vm.sh" ;;
    nas) BACKEND_SCRIPT="./scripts/quartus_backend_nas.sh" ;;
esac

START=$(date +%s)
if ! "$BACKEND_SCRIPT"; then
    fail "Quartus backend '$BACKEND' failed"
    info "Job directory: $LOCAL_JOB_DIR"
    info "Backend log:   $LOCAL_LOG"
    exit 1
fi
END=$(date +%s)
ELAPSED=$((END - START))

MAP_RPT="$LOCAL_JOB_DIR/${PROJECT}.map.rpt"
FIT_RPT="$LOCAL_JOB_DIR/${PROJECT}.fit.rpt"
STA_RPT="$LOCAL_JOB_DIR/${PROJECT}.sta.rpt"

if [[ ! -f "$MAP_RPT" ]]; then
    fail "Missing map report: $MAP_RPT"
    info "Job directory: $LOCAL_JOB_DIR"
    info "Backend log:   $LOCAL_LOG"
    exit 1
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  fabi386 Quartus Synthesis Resource Report${NC}"
echo -e "${BOLD}  Device: Cyclone V 5CSEBA6U23I7 (DE10-Nano)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""

ALM_EST="?" ALUT_COUNT="?" REG_COUNT="?" MEM_BITS="?" DSP_COUNT="?"

if grep -q "Resource Usage Summary" "$MAP_RPT"; then
    ALM_EST=$(extract_summary_value "Estimate of Logic utilization" "$MAP_RPT")
    ALUT_COUNT=$(extract_summary_value "Combinational ALUT usage for logic" "$MAP_RPT")
    REG_COUNT=$(extract_summary_value "Dedicated logic registers" "$MAP_RPT")
    MEM_BITS=$(extract_summary_value "Total block memory bits" "$MAP_RPT")
    DSP_COUNT=$(extract_summary_value "Total DSP Blocks" "$MAP_RPT")

    printf "  %-30s %s / 41,910\n" "ALMs (estimated):" "${ALM_EST:-?}"
    printf "  %-30s %s\n" "Combinational ALUTs:" "${ALUT_COUNT:-?}"
    printf "  %-30s %s\n" "Dedicated Registers:" "${REG_COUNT:-?}"
    printf "  %-30s %s\n" "Block Memory Bits:" "${MEM_BITS:-?}"
    printf "  %-30s %s / 112\n" "DSP Blocks:" "${DSP_COUNT:-?}"
else
    warn "Could not parse resource summary from report"
    grep -i "logic\|ALM\|register\|memory\|DSP" "$MAP_RPT" | head -10 || true
fi

echo ""

if grep -q "Compilation Hierarchy Node" "$MAP_RPT"; then
    echo -e "${BOLD}  Per-Module Breakdown (ALUTs / Regs):${NC}"
    # Use awk to avoid SIGPIPE from head in a pipe under set -e
    awk -F ';' '
        /Compilation Hierarchy Node/ { found=1; next }
        found && /^\+/ { sep++; if (sep > 1) exit; next }
        found && /^;/ && /(f386_|alu_)/ && count<25 {
            name=$2; aluts=$3; regs=$4
            gsub(/\|/, "", name); gsub(/^ +| +$/, "", name)
            gsub(/^ +| +$/, "", aluts); gsub(/^ +| +$/, "", regs)
            if (length(name) > 0 && length(aluts) > 0)
                printf "    %-45s %6s / %s\n", name, aluts, regs
            count++
        }
    ' "$MAP_RPT"
    echo ""
fi

if [[ $FULL_COMPILE -eq 1 && -f "$STA_RPT" ]]; then
    FMAX_LINE=$(grep -i "Fmax" "$STA_RPT" | head -1 || true)
    if [[ -n "$FMAX_LINE" ]]; then
        echo "  $FMAX_LINE"
        echo ""
    fi
fi

mkdir -p docs
if [[ ! -f "$HISTORY_LOG" ]]; then
    echo "date,phase,alms,regs,dsp,block_mem_bits,elapsed_sec,notes" > "$HISTORY_LOG"
fi
DATE=$(date +%Y-%m-%d)
echo "${DATE},,${ALM_EST:-?},${REG_COUNT:-?},${DSP_COUNT:-?},${MEM_BITS:-?},${ELAPSED},quartus_synth_check:${BACKEND}" >> "$HISTORY_LOG"
ok "Appended to ${HISTORY_LOG}"

echo ""
info "Job directory: $LOCAL_JOB_DIR"
info "Backend log:   $LOCAL_LOG"
if [[ -f "$FIT_RPT" ]]; then
    info "Fitter report: $FIT_RPT"
fi
if [[ -f "$STA_RPT" ]]; then
    info "Timing report: $STA_RPT"
fi
