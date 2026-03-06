#!/usr/bin/env bash
# ============================================================================
# fabi386: Yosys Per-Module Resource Check (Native ARM, No Emulation)
# ============================================================================
# Runs sv2v → Yosys synthesis on individual modules or the full design
# and reports cell counts. Runs natively on Apple Silicon in seconds.
#
# Usage:
#   ./scripts/yosys_resource_check.sh                  # All modules
#   ./scripts/yosys_resource_check.sh f386_cpuid       # Single module
#   ./scripts/yosys_resource_check.sh --full           # Full design (flattened)
# ============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
DIM='\033[2m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

CSV_LOG="docs/yosys_resource_history.csv"
PKG="rtl/top/f386_pkg.sv"

# --- Module dependency map ---
# Format: "top_module|file1 file2 ..."
declare -A MODULES
MODULES=(
    [f386_decode]="f386_decode|rtl/core/f386_decode.sv"
    [f386_execute_stage]="f386_execute_stage|rtl/core/f386_execute_stage.sv rtl/core/f386_alu.v rtl/core/f386_alu_simd.sv rtl/core/f386_alu_bitcount.sv rtl/core/f386_fpu_spatial.v rtl/core/f386_divider.sv rtl/core/f386_multiplier.sv"
    [f386_rob]="f386_rob|rtl/core/f386_rob.sv"
    [f386_issue_queue]="f386_issue_queue|rtl/core/f386_issue_queue.sv rtl/core/f386_producer_matrix.sv rtl/core/f386_ready_bit_table.sv rtl/core/f386_wakeup_select.sv"
    [f386_register_rename]="f386_register_rename|rtl/core/f386_register_rename.sv rtl/core/f386_rename_maptable.sv rtl/core/f386_rename_freelist.sv rtl/core/f386_rename_busytable.sv rtl/primitives/f386_distributed_ram.sv rtl/primitives/f386_freelist_multiwidth.sv"
    [f386_specbits]="f386_specbits|rtl/core/f386_specbits.sv"
    [f386_ftq]="f386_ftq|rtl/core/f386_ftq.sv"
    [f386_fetch_fifo]="f386_fetch_fifo|rtl/core/f386_fetch_fifo.sv"
    # NOTE: f386_dispatch excluded — uses SV interface ports (f386_uv_pipe_if), can't synthesize standalone
    # Resource usage: ~200 ALMs (thin scoreboard + pairing logic)
    [f386_exception_unit]="f386_exception_unit|rtl/core/f386_exception_unit.sv"
    [f386_cpuid]="f386_cpuid|rtl/core/f386_cpuid.sv"
    [f386_microcode]="f386_microcode_sequencer|rtl/core/f386_microcode_sequencer.sv rtl/core/f386_microcode_rom_gen.sv"
    # NOTE: f386_lsq excluded — byte-granular CAM forwarding causes Yosys techmap to take >10 min
    # Resource usage: ~1,200 ALMs + 0 M10K (CAM-dominated logic, no BRAM)
    # NOTE: f386_dcache, f386_tlb, f386_l2_cache, f386_l2_cache_sp excluded — their large mux trees
    # (4-way PLRU, fully-associative CAM) cause Yosys proc pass to take >30 min.
    # These are BRAM-dominated; resource usage is predictable from parameterization:
    #   dcache: ~950 ALMs + 5 M10K    tlb: ~1350 ALMs + 0 M10K
    #   l2: ~300 ALMs + 64 M10K       l2_sp: ~2700 ALMs + 64 M10K (delta: MSHRs ~2400 ALMs)
    [f386_branch_predict]="f386_branch_predict_hybrid|rtl/core/f386_branch_predict.sv rtl/core/f386_branch_predict_gshare.sv rtl/core/f386_branch_predict_hybrid.sv rtl/core/f386_ras_unit.sv"
    [f386_sys_regs]="f386_sys_regs|rtl/core/f386_sys_regs.sv"
    [f386_seg_cache]="f386_seg_cache|rtl/core/f386_seg_cache.sv"
    [f386_msr_file]="f386_msr_file|rtl/core/f386_msr_file.sv"
    [f386_shadow_stack]="f386_shadow_stack|rtl/core/f386_shadow_stack.sv rtl/primitives/f386_block_ram.sv"
    [f386_v86_safe_trap]="f386_v86_safe_trap|rtl/core/f386_v86_safe_trap.sv"
    [f386_semantic_logger]="f386_semantic_logger|rtl/core/f386_semantic_logger.sv"
    [f386_pic]="f386_pic|rtl/soc/f386_pic.sv"
    [f386_pit]="f386_pit|rtl/soc/f386_pit.sv"
    [f386_ps2]="f386_ps2|rtl/soc/f386_ps2.sv"
    [f386_vga]="f386_vga|rtl/soc/f386_vga.sv"
    [f386_iobus]="f386_iobus|rtl/soc/f386_iobus.sv"
    [f386_vbe_accel]="f386_svga_accel|rtl/soc/f386_vbe_accel.sv"
    [f386_aar_engine]="f386_aar_engine|rtl/soc/f386_aar_engine.sv rtl/soc/f386_semantic_tagger.sv rtl/soc/f386_shadow_stack.sv rtl/soc/f386_stride_detector.sv rtl/soc/f386_telemetry_dma.sv"
    [f386_mem_ctrl]="f386_mem_ctrl|rtl/top/f386_mem_ctrl.sv"
    [f386_pll]="f386_pll|rtl/top/f386_pll.sv"
)

synth_module() {
    local name=$1
    local entry="${MODULES[$name]}"
    local top="${entry%%|*}"
    local files="${entry#*|}"
    local vfile="$TMPDIR/${name}.v"
    local logfile="$TMPDIR/${name}.log"

    # sv2v translate (include rtl/core for .svh files)
    sv2v -I rtl/core $PKG $files > "$vfile" 2>/dev/null

    # Yosys synthesis + stat
    # Use hierarchy+proc+opt+techmap instead of synth -flatten to avoid ABC
    # (ABC is extremely slow on large mux trees and unnecessary for cell counts)
    yosys -p "
        read_verilog $vfile;
        hierarchy -top $top;
        proc; opt; memory; opt;
        techmap; opt;
        stat
    " > "$logfile" 2>&1 || true

    # Extract cell counts from final stat block
    local cells muxes ffs
    cells=$(grep -E '^\s+[0-9]+ cells$' "$logfile" 2>/dev/null | tail -1 | awk '{print $1}' || true)
    muxes=$(grep '$_MUX_' "$logfile" 2>/dev/null | tail -1 | awk '{print $1}' || true)
    ffs=$(grep -E '\$_DFF|\$_DFFE' "$logfile" 2>/dev/null | awk '{sum += $1} END {print sum+0}' || true)

    cells=${cells:-0}
    muxes=${muxes:-0}
    ffs=${ffs:-0}

    if [[ "$cells" -eq 0 ]] && grep -q "ERROR" "$logfile" 2>/dev/null; then
        return 1
    fi

    local alm_est=$(( (cells + 4) / 5 ))
    printf "  %-28s %8s %8s %8s %8s\n" "$name" "$cells" "$muxes" "$ffs" "~$alm_est"

    # Return values via temp files for aggregation
    echo "$cells" > "$TMPDIR/${name}.cells"
    echo "$ffs" > "$TMPDIR/${name}.ffs"
}

synth_full() {
    echo -e "${CYAN}[INFO]${NC} Full-design sv2v translate..."
    local vfile="$TMPDIR/f386_full.v"
    sv2v rtl/top/f386_pkg.sv rtl/primitives/*.sv rtl/core/*.sv rtl/memory/*.sv > "$vfile" 2>/dev/null

    echo -e "${CYAN}[INFO]${NC} Yosys synthesis (this may take a few minutes)..."
    yosys -p "
        read_verilog $vfile;
        hierarchy -top f386_ooo_core_top;
        proc; opt; memory; opt;
        techmap; opt;
        stat
    " 2>&1 | grep -A 50 "Printing statistics" | tail -40
}

print_header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  fabi386 Yosys Resource Check (native ARM, sv2v + Yosys)${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "  ${DIM}%-28s %8s %8s %8s %8s${NC}\n" "Module" "Cells" "MUXes" "FFs" "ALM est"
    printf "  %-28s %8s %8s %8s %8s\n" "----------------------------" "--------" "--------" "--------" "--------"
}

# --- Main ---

if [[ "${1:-}" == "--full" ]]; then
    synth_full
    exit 0
fi

if [[ -n "${1:-}" ]]; then
    if [[ -z "${MODULES[${1}]:-}" ]]; then
        echo "Unknown module: $1"
        echo "Available:"
        printf '  %s\n' $(echo "${!MODULES[@]}" | tr ' ' '\n' | sort)
        exit 1
    fi
    print_header
    synth_module "$1"
    echo ""
    exit 0
fi

# All modules
START=$(date +%s)
print_header

SORTED_NAMES=$(echo "${!MODULES[@]}" | tr ' ' '\n' | sort)

for name in $SORTED_NAMES; do
    synth_module "$name" || printf "  %-28s %8s %8s %8s %8s\n" "$name" "SKIP" "" "" "(failed)"
done

END=$(date +%s)

# Aggregate totals
TOTAL_CELLS=0
TOTAL_FFS=0
for name in $SORTED_NAMES; do
    c=$(cat "$TMPDIR/${name}.cells" 2>/dev/null || echo 0)
    f=$(cat "$TMPDIR/${name}.ffs" 2>/dev/null || echo 0)
    TOTAL_CELLS=$(( TOTAL_CELLS + c ))
    TOTAL_FFS=$(( TOTAL_FFS + f ))
done
TOTAL_ALM=$(( (TOTAL_CELLS + 4) / 5 ))

printf "  %-28s %8s %8s %8s %8s\n" "----------------------------" "--------" "--------" "--------" "--------"
printf "  ${BOLD}%-28s %8s %8s %8s %8s${NC}\n" "SUM (with overlap)" "$TOTAL_CELLS" "" "$TOTAL_FFS" "~$TOTAL_ALM"
echo ""
echo -e "  ${DIM}Excluded (BRAM/CAM-heavy): dcache (~950), tlb (~1350), l2 (~300), l2_sp (~2700), lsq (~1200) = ~6,500 ALMs${NC}"
echo -e "  ${DIM}Excluded (SV interface): dispatch (~200 ALMs)${NC}"
echo -e "  ${DIM}Note: Sum overcounts ~10-15% vs real Quartus due to cross-module optimization${NC}"
echo -e "  ${DIM}ALM estimate: cells/5 (rough Cyclone V approximation)${NC}"
echo -e "  ${DIM}Completed in $((END - START))s${NC}"
echo ""

# Log to CSV
if [[ ! -f "$CSV_LOG" ]]; then
    echo "date,total_cells,total_ffs,alm_estimate,notes" > "$CSV_LOG"
fi
echo "$(date +%Y-%m-%d),$TOTAL_CELLS,$TOTAL_FFS,$TOTAL_ALM,yosys per-module sum" >> "$CSV_LOG"
echo -e "${GREEN}[OK]${NC} Appended to $CSV_LOG"
echo ""
