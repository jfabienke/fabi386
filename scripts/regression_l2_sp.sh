#!/usr/bin/env bash
# ============================================================================
# fabi386: L2 Split-Phase Regression Gate
# ============================================================================
# Three gates that must all pass before committing L2/memory-fabric changes:
#   Gate 1: Verilator L2_SP directed tests (ctest)
#   Gate 2: sv2v syntax check (gate OFF + gate ON)
#   Gate 3: Yosys smoke (f386_mem_ctrl)
#
# Usage:
#   ./scripts/regression_l2_sp.sh
# ============================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

failures=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { echo -e "  ${RED}FAIL${NC} $1"; }

# ── Gate 1: Verilator L2_SP tests ──────────────────────────────────────────
gate1_verilator() {
    echo -e "\n${BOLD}Gate 1: Verilator L2_SP tests${NC}"
    local bdir="bench/verilator/build"

    # Configure if build directory missing
    if [[ ! -d "$bdir" ]]; then
        echo "  Configuring cmake..."
        cmake -S bench/verilator -B "$bdir" -DCMAKE_BUILD_TYPE=Release || return 1
    fi

    # Build test targets
    echo "  Building test_l2_sp + test_microcode_seq..."
    local njobs
    njobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    cmake --build "$bdir" --target test_l2_sp -j "$njobs" || return 1
    cmake --build "$bdir" --target test_microcode_seq -j "$njobs" || return 1

    # Run
    echo "  Running ctest..."
    (cd "$bdir" && ctest -R '^(l2_sp|microcode_seq)$' --output-on-failure) || return 1
}

# ── Gate 2: sv2v syntax (gate OFF + gate ON) ──────────────────────────────
gate2_sv2v() {
    echo -e "\n${BOLD}Gate 2: sv2v syntax check${NC}"
    mkdir -p build

    # --- Gate OFF (default config) ---
    echo "  sv2v gate OFF..."
    sv2v -I rtl/core \
        rtl/top/f386_pkg.sv rtl/primitives/*.sv rtl/core/*.sv \
        rtl/memory/*.sv rtl/soc/*.sv rtl/top/*.sv \
        > build/f386_sv2v_full.v 2>build/f386_sv2v_full.log || return 1
    pass "gate OFF"

    # --- Gate ON (MEM_FABRIC enabled) ---
    echo "  sv2v gate ON..."
    local tmp_pkg
    tmp_pkg=$(mktemp "${TMPDIR:-/tmp}/f386_pkg_fabric.XXXXXX.sv")
    trap "rm -f '$tmp_pkg'" RETURN

    sed -E \
        -e "s/(CONF_ENABLE_LSQ_MEMIF)[[:space:]]*=[[:space:]]*1'b0/\1 = 1'b1/" \
        -e "s/(CONF_ENABLE_L2_CACHE)[[:space:]]*=[[:space:]]*1'b0/\1 = 1'b1/" \
        -e "s/(CONF_ENABLE_MEM_FABRIC)[[:space:]]*=[[:space:]]*1'b0/\1 = 1'b1/" \
        -e "s/(CONF_ENABLE_MICROCODE)[[:space:]]*=[[:space:]]*1'b0/\1 = 1'b1/" \
        rtl/top/f386_pkg.sv > "$tmp_pkg"

    # Verify substitution actually happened
    if ! grep -q "CONF_ENABLE_MEM_FABRIC.*1'b1" "$tmp_pkg"; then
        echo "  ERROR: sed substitution failed for CONF_ENABLE_MEM_FABRIC"
        return 1
    fi

    # Build source list: patched pkg + everything except original pkg
    local top_files
    top_files=$(ls rtl/top/*.sv | grep -v f386_pkg.sv)

    sv2v -I rtl/core \
        "$tmp_pkg" rtl/primitives/*.sv rtl/core/*.sv \
        rtl/memory/*.sv rtl/soc/*.sv $top_files \
        > build/f386_sv2v_fabric.v 2>build/f386_sv2v_fabric.log || return 1
    pass "gate ON"
}

# ── Gate 3: Yosys smoke ───────────────────────────────────────────────────
gate3_yosys() {
    echo -e "\n${BOLD}Gate 3: Yosys smoke (f386_mem_ctrl)${NC}"
    ./scripts/yosys_resource_check.sh f386_mem_ctrl || return 1
}

# ── Run all gates ─────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}fabi386 L2_SP Regression Gate${NC}"

if gate1_verilator; then pass "Gate 1"; else fail "Gate 1"; ((failures++)); fi
if gate2_sv2v;      then pass "Gate 2"; else fail "Gate 2"; ((failures++)); fi
if gate3_yosys;     then pass "Gate 3"; else fail "Gate 3"; ((failures++)); fi

echo ""
if [[ "$failures" -eq 0 ]]; then
    echo -e "${BOLD}${GREEN}All gates passed.${NC}"
else
    echo -e "${BOLD}${RED}${failures} gate(s) failed.${NC}"
fi

exit "$failures"
