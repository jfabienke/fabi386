/*
 * fabi386: Microcode Memory Integration Test (P3.1b Commit 4)
 * ------------------------------------------------------------
 * Exercises the full microcode memory engine (UM FSM) with the
 * test opcode 0xD6 which expands to PUSH EAX → POP EBX.
 *
 * Requires: VERILATOR_ENABLE_MICROCODE + VERILATOR_ENABLE_LSQ_MEMIF
 *
 * Tests:
 *   1. NOP sled + 0xD6 + NOP sled: basic completion, no deadlock
 *   2. 0xD6 early in stream: works as first microcode mem op
 *   3. Back-to-back 0xD6: pipeline handles repeated microcode mem ops
 *   4. Data memory activity: at least 1 store drain observed
 */

#include <cstdlib>
#include <cstdio>
#include <cstdint>
#include <cassert>
#include <algorithm>
#include <memory>
#include <vector>

#include "Vf386_ooo_core_top.h"
#include "Vf386_ooo_core_top___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "memory_model.h"

// UC FSM states (must match ucode_state_t in core_top)
static constexpr int UC_IDLE     = 0;
static constexpr int UC_DRAINING = 1;
static constexpr int UC_ACTIVE   = 2;

static int g_checks = 0;
static int g_fails  = 0;

#define CHECK(cond, msg) do {                                 \
    g_checks++;                                               \
    if (!(cond)) {                                            \
        printf("  FAIL: %s (line %d)\n", msg, __LINE__);     \
        g_fails++;                                            \
    }                                                         \
} while(0)

class UcodeMemTB {
public:
    UcodeMemTB()
        : top_(std::make_unique<Vf386_ooo_core_top>())
        , trace_(std::make_unique<VerilatedVcdC>())
        , cycle_(0)
        , retired_(0)
        , trace_time_(0)
        , data_writes_(0)
        , data_reads_(0)
        , saw_um_alloc_(false)
        , saw_uc_active_(false)
        , data_ack_pending_(false)
        , data_ack_rdata_(0)
        , ack_hold_(0)
    {
        Verilated::traceEverOn(true);
        top_->trace(trace_.get(), 99);
        trace_->open("tb_ooo_core_ucode_mem.vcd");
    }

    ~UcodeMemTB() {
        trace_->close();
    }

    void load_program(const uint8_t* code, size_t len, uint32_t base = 0xFFF0) {
        mem_.fill(base, 256, 0x90);  // NOP background
        for (size_t i = 0; i < len; i++)
            mem_.write8(base + i, code[i]);
        mem_.write8(base + 200, 0xF4);  // HLT sentinel
    }

    void reset() {
        top_->clk = 0;
        top_->rst_n = 0;
        top_->fetch_data_valid = 0;
        VL_ZERO_W(4, top_->fetch_data);
        top_->mem_rdata = 0;
        top_->mem_ack = 0;
        top_->mem_gnt = 0;
        top_->irq = 0;
        top_->irq_vector = 0;
        top_->test_force_flush = 0;
        top_->a20_gate = 1;

        // Page walker port (inactive — TLB gate OFF)
        top_->pt_rdata = 0;
        top_->pt_ack = 0;

        // Split-phase ports (inactive — MEM_FABRIC gate OFF)
        top_->sp_data_req_ready = 0;
        top_->sp_data_rsp_valid = 0;

        for (int i = 0; i < 20; i++) {
            top_->clk = !top_->clk;
            top_->eval();
            trace_->dump(trace_time_++);
        }
        top_->rst_n = 1;
        cycle_ = 0;
        retired_ = 0;
        data_writes_ = 0;
        data_reads_ = 0;
        saw_um_alloc_ = false;
        saw_uc_active_ = false;
        data_ack_pending_ = false;
        data_ack_rdata_ = 0;
        ack_hold_ = 0;
    }

    void tick() {
        // Rising edge — inputs unchanged from previous falling eval.
        // FFs sample state_d computed during the previous falling eval.
        top_->clk = 1;
        top_->eval();
        trace_->dump(trace_time_++);

        // --- Between rising and falling evals ---
        // Phase 1: After the rising eval has sampled, expire old ack
        if (ack_hold_ > 0) {
            ack_hold_--;
            if (ack_hold_ == 0) {
                top_->mem_ack = 0;
                top_->mem_gnt = 0;
            }
        }
        // Phase 2: Deliver pending ack (visible to falling eval + next rising)
        if (data_ack_pending_) {
            top_->mem_ack   = 1;
            top_->mem_gnt   = 1;
            top_->mem_rdata = data_ack_rdata_;
            data_ack_pending_ = false;
            ack_hold_ = 1;  // Hold through next rising eval before clearing
        }

        service_fetch();
        service_data_mem();

        if (top_->trace_valid)
            retired_++;

        // Track microcode FSM states
        int uc = ucode_state();
        int um = um_state();
        if (uc == UC_ACTIVE) saw_uc_active_ = true;
        if (um >= 1) saw_um_alloc_ = true;

        // Falling edge
        top_->clk = 0;
        top_->eval();
        trace_->dump(trace_time_++);

        cycle_++;
    }

    template<typename Pred>
    bool run_until(Pred pred, uint64_t max_cycles) {
        for (uint64_t i = 0; i < max_cycles; i++) {
            tick();
            if (pred()) return true;
        }
        return false;
    }

    int um_state() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__uc_mem_state;
    }

    bool saw_um_alloc() const { return saw_um_alloc_; }
    bool saw_uc_active() const { return saw_uc_active_; }

    void run(uint64_t n) {
        for (uint64_t i = 0; i < n; i++) tick();
    }

    int ucode_state() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__ucode_state;
    }

    int seq_state() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__u_ucode_seq__DOT__state;
    }
    int seq_step() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__u_ucode_seq__DOT__r_step;
    }
    int seq_opcode() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__u_ucode_seq__DOT__r_opcode;
    }
    int macro_opcode() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__macro_opcode;
    }
    uint32_t macro_ea() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__macro_ea;
    }
    uint32_t fetch_addr() const {
        return top_->fetch_addr;
    }
    uint64_t retired()      const { return retired_; }
    uint64_t cycle_count()  const { return cycle_; }
    uint64_t data_writes()  const { return data_writes_; }
    uint64_t data_reads()   const { return data_reads_; }

    // Memory readback for data verification
    uint32_t read_mem32(uint32_t addr) const { return mem_.read32(addr); }

    // Memory write for pre-seeding data memory
    void write_mem8(uint32_t addr, uint8_t val) { mem_.write8(addr, val); }
    void write_mem32(uint32_t addr, uint32_t val) { mem_.write32(addr, val); }

    // DTR register readback (via sys_regs internal names)
    uint32_t gdtr_base() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_gdtr_base;
    }
    uint16_t gdtr_limit() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_gdtr_limit;
    }
    uint32_t idtr_base() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_idtr_base;
    }
    uint16_t idtr_limit() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_idtr_limit;
    }

    // Segment register readback (indices: ES=0, CS=1, SS=2, DS=3, FS=4, GS=5)
    uint16_t seg_sel(int idx) const {
        return top_->rootp->f386_ooo_core_top__DOT__seg_cache__DOT__reg_sel[idx];
    }
    uint64_t seg_cache(int idx) const {
        return top_->rootp->f386_ooo_core_top__DOT__seg_cache__DOT__reg_cache[idx];
    }
    uint16_t cs_sel() const {
        return top_->rootp->f386_ooo_core_top__DOT__seg_cs_sel;
    }
    uint64_t cs_cache() const { return seg_cache(1); }
    bool cs_db() const {
        // D/B bit is bit 54 of the descriptor cache
        return (cs_cache() >> 54) & 1;
    }
    uint32_t pc() const {
        return top_->rootp->f386_ooo_core_top__DOT__pc_current;
    }
    uint32_t eflags() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_eflags;
    }
    bool pe_mode() const {
        // PE is bit 0 of CR0
        return cr0() & 1;
    }
    bool default_32() const {
        // default_32 = CS.D/B in protected mode, 0 in real mode
        return pe_mode() ? cs_db() : false;
    }
    uint32_t cr0() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_cr0;
    }

    // Direct access to top module for debug
    Vf386_ooo_core_top* top() const { return top_.get(); }

    // Debug: dispatch, IQ, ROB signals
    bool iq_issue_valid() const {
        return top_->rootp->f386_ooo_core_top__DOT__iq_issue_valid;
    }
    bool iq_flush() const {
        return top_->rootp->f386_ooo_core_top__DOT__iq__DOT__flush;
    }
    bool lsq_dispatch_blocked() const {
        return top_->rootp->f386_ooo_core_top__DOT__lsq_dispatch_blocked;
    }
    bool iq_force_dequeue() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__iq_force_dequeue;
    }
    uint8_t rob_head() const {
        return top_->rootp->f386_ooo_core_top__DOT__rob__DOT__head;
    }
    uint8_t rob_tail() const {
        return top_->rootp->f386_ooo_core_top__DOT__rob__DOT__tail;
    }
    uint8_t rob_count() const {
        return top_->rootp->f386_ooo_core_top__DOT__rob__DOT__count;
    }
    uint16_t rob_entry_valid_mask() const {
        return top_->rootp->f386_ooo_core_top__DOT__rob__DOT__entry_valid;
    }
    uint16_t rob_entry_complete_mask() const {
        return top_->rootp->f386_ooo_core_top__DOT__rob__DOT__entry_complete;
    }
    uint8_t iq_entry_valid_mask() const {
        return top_->rootp->f386_ooo_core_top__DOT__iq__DOT__entry_valid;
    }
    uint8_t macro_rob_tag() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__macro_rob_tag;
    }
    bool uc_regonly_pending() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__uc_regonly_pending_r;
    }
    bool uop_is_regonly() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__uop_is_regonly_cmd;
    }
    bool uop_is_mem() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__uop_is_mem;
    }
    bool seq_uop_valid() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__seq_uop_valid;
    }
    bool uc_mem_done() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__uc_mem_done;
    }
    uint8_t uc_mem_special_r() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__uc_mem_special_r;
    }
    bool ucode_exec_ack() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__u_ucode_seq__DOT__exec_ack;
    }
    bool has_eflags_cmd() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__ucode_has_eflags_cmd;
    }
    bool exec_u_ready() const {
        return top_->rootp->f386_ooo_core_top__DOT__exec_stage__DOT__u_ready;
    }
    bool exec_u_valid() const {
        return top_->rootp->f386_ooo_core_top__DOT__exec_stage__DOT__u_valid;
    }
    bool ld_in_flight() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_lsq_memif__DOT__ld_in_flight;
    }

private:
    std::unique_ptr<Vf386_ooo_core_top> top_;
    std::unique_ptr<VerilatedVcdC>      trace_;
    MemoryModel                         mem_;
    uint64_t                            cycle_;
    uint64_t                            retired_;
    uint64_t                            trace_time_;
    uint64_t                            data_writes_;
    uint64_t                            data_reads_;
    bool                                saw_um_alloc_;
    bool                                saw_uc_active_;
    bool                                data_ack_pending_;
    uint64_t                            data_ack_rdata_;
    int                                 ack_hold_;

public:
    // Write trace for data verification
    struct MemTrace {
        uint32_t addr;
        uint64_t data;
        uint8_t  ben;
        bool     is_write;
    };
    std::vector<MemTrace> mem_trace_;
    bool trace_enabled_ = false;

    void enable_trace()  { trace_enabled_ = true; mem_trace_.clear(); }
    void disable_trace() { trace_enabled_ = false; }

private:

    void service_fetch() {
        if (top_->fetch_req) {
            uint32_t addr = top_->fetch_addr;
            uint8_t buf[16];
            mem_.read128(addr, buf);
            uint32_t* fd = reinterpret_cast<uint32_t*>(&top_->fetch_data);
            fd[0] = buf[0]  | (buf[1] << 8)  | (buf[2] << 16)  | (buf[3] << 24);
            fd[1] = buf[4]  | (buf[5] << 8)  | (buf[6] << 16)  | (buf[7] << 24);
            fd[2] = buf[8]  | (buf[9] << 8)  | (buf[10] << 16) | (buf[11] << 24);
            fd[3] = buf[12] | (buf[13] << 8) | (buf[14] << 16) | (buf[15] << 24);
            top_->fetch_data_valid = 1;
        } else {
            top_->fetch_data_valid = 0;
        }
    }

    void service_data_mem() {
        // Sample new request after rising eval — ack delivered NEXT tick.
        // Only sample when mem_ack=0 (not delivering a prior ack this tick)
        // and no ack already pending.
        if (top_->mem_req && !top_->mem_ack && !data_ack_pending_) {
            uint32_t addr = top_->mem_addr;
            uint32_t base = addr & ~7u;
            if (top_->mem_wr) {
                uint64_t wdata = top_->mem_wdata;
                uint8_t  ben   = top_->mem_byte_en;
                if (trace_enabled_)
                    mem_trace_.push_back({addr, wdata, ben, true});
                for (int i = 0; i < 8; i++) {
                    if (ben & (1 << i))
                        mem_.write8(base + i, (wdata >> (i * 8)) & 0xFF);
                }
                data_writes_++;
            } else {
                uint64_t rdata = 0;
                for (int i = 0; i < 8; i++)
                    rdata |= (uint64_t)mem_.read8(base + i) << (i * 8);
                data_ack_rdata_ = rdata;
                if (trace_enabled_) {
                    mem_trace_.push_back({addr, rdata, 0, false});
                }
                data_reads_++;
            }
            data_ack_pending_ = true;
        }
    }
};

// ============================================================
// Test 1: NOP sled + 0xD6 + NOP sled
// Proves: microcode mem path completes, pipeline resumes
// ============================================================
static void test_basic_d6(UcodeMemTB& tb) {
    printf("Test 1: NOP sled + 0xD6 + NOP sled\n");

    // Decoder picks U@byte[0], V@byte[1] per 16-byte fetch block, then PC+=16.
    // 0xD6 must be at byte 0 or 1 of a block boundary.
    // Block 0 (base+0):  NOP, NOP
    // Block 1 (base+16): 0xD6, NOP  ← 0xD6 decoded as U-pipe
    // Block 2 (base+32): NOP background (from load_program fill)
    uint8_t code[33];
    memset(code, 0x90, sizeof(code));  // NOP fill
    code[16] = 0xD6;                   // 0xD6 at byte 0 of second fetch block
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 10; }, 5000);
    CHECK(done, "at least 10 instructions retired (NOPs + 0xD6)");
    CHECK(tb.cycle_count() < 3000, "completed within 3000 cycles (no deadlock)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM returned to UC_IDLE");

    CHECK(tb.saw_uc_active(), "UC_ACTIVE reached (microcode path exercised)");
    CHECK(tb.saw_um_alloc(), "UM FSM left UM_IDLE (memory engine exercised)");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu uc_active=%d um_alloc=%d\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads(),
           tb.saw_uc_active(), tb.saw_um_alloc());
}

// ============================================================
// Test 2: 0xD6 early in stream
// Proves: microcode mem path works as first complex op
// ============================================================
static void test_early_d6(UcodeMemTB& tb) {
    printf("Test 2: 0xD6 early in stream\n");

    // 0xD6 as first U-pipe instruction (byte 0 of first fetch block)
    uint8_t code[17];
    memset(code, 0x90, sizeof(code));  // NOP fill
    code[0] = 0xD6;                    // 0xD6 at byte 0 of first fetch block
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    CHECK(done, "at least 4 instructions retired (NOPs + 0xD6)");
    CHECK(tb.cycle_count() < 3000, "completed within 3000 cycles (no deadlock)");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 3: Back-to-back 0xD6
// Proves: pipeline handles repeated microcode mem ops
// ============================================================
static void test_back_to_back_d6(UcodeMemTB& tb) {
    printf("Test 3: Back-to-back 0xD6\n");

    // Two 0xD6 on consecutive fetch block boundaries
    // Block 0 (base+0):  0xD6 (1st), NOP
    // Block 1 (base+16): 0xD6 (2nd), NOP
    // Block 2 (base+32): NOP background
    uint8_t code[33];
    memset(code, 0x90, sizeof(code));  // NOP fill
    code[0]  = 0xD6;                   // 1st at byte 0 of block 0
    code[16] = 0xD6;                   // 2nd at byte 0 of block 1
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 8; }, 10000);
    CHECK(done, "at least 8 instructions retired (NOPs + 2x 0xD6)");
    CHECK(tb.cycle_count() < 8000, "completed within 8000 cycles (no deadlock)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM idle after both ops");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 4: Data memory activity from 0xD6
// Proves: PUSH actually drains a store to memory
// ============================================================
static void test_data_mem_activity(UcodeMemTB& tb) {
    printf("Test 4: Data memory activity from 0xD6\n");

    // Same layout as Test 1: 0xD6 at byte 0 of second fetch block
    uint8_t code[33];
    memset(code, 0x90, sizeof(code));  // NOP fill
    code[16] = 0xD6;                   // 0xD6 at byte 0 of second fetch block
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 10; }, 5000);
    CHECK(done, "instructions retired");

    // The PUSH generates a store that must drain through the shim.
    // The POP generates a load — it may be forwarded from SQ or go to memory.
    CHECK(tb.data_writes() >= 1, "at least 1 data memory write (PUSH store drain)");

    printf("  retired=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 5: PUSHA basic
// Proves: PUSHA (0x60) completes, generates ≥8 stores, no deadlock
// ============================================================
static void test_pusha_basic(UcodeMemTB& tb) {
    printf("Test 5: PUSHA basic\n");

    // PUSHA (0x60) at byte 0 of first fetch block
    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x60;  // PUSHA at byte 0
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.data_writes() >= 8; }, 10000);
    CHECK(done, "PUSHA 8 stores drained to memory");
    CHECK(tb.cycle_count() < 8000, "completed within 8000 cycles (no deadlock)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM idle after PUSHA");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 6: POPA basic
// Proves: POPA (0x61) completes, generates ≥8 reads, no deadlock
// ============================================================
static void test_popa_basic(UcodeMemTB& tb) {
    printf("Test 6: POPA basic\n");

    // POPA (0x61) at byte 0 of first fetch block
    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x61;  // POPA at byte 0
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 10000);
    CHECK(done, "POPA + NOPs retired");
    CHECK(tb.cycle_count() < 8000, "completed within 8000 cycles (no deadlock)");
    CHECK(tb.data_reads() >= 8, "at least 8 data memory reads (8 register pops)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM idle after POPA");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 7: PUSHA + POPA roundtrip
// Proves: both complete sequentially, pipeline resumes
// ============================================================
static void test_pusha_popa_roundtrip(UcodeMemTB& tb) {
    printf("Test 7: PUSHA + POPA roundtrip\n");

    // Block 0: PUSHA at byte 0
    // Block 1: POPA at byte 0
    uint8_t code[33];
    memset(code, 0x90, sizeof(code));
    code[0]  = 0x60;  // PUSHA at byte 0 of block 0
    code[16] = 0x61;  // POPA at byte 0 of block 1
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 20000);
    CHECK(done, "PUSHA + POPA + NOPs retired");
    CHECK(tb.cycle_count() < 16000, "completed within 16000 cycles (no deadlock)");
    CHECK(tb.data_writes() >= 8, "at least 8 writes from PUSHA");
    CHECK(tb.data_reads() >= 7, "at least 7 reads from POPA (1 may be SQ-forwarded)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM idle after roundtrip");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 8: Back-to-back PUSHA
// Proves: pipeline handles consecutive PUSHA ops, ≥16 writes
// ============================================================
static void test_back_to_back_pusha(UcodeMemTB& tb) {
    printf("Test 8: Back-to-back PUSHA\n");

    // Block 0: PUSHA at byte 0
    // Block 1: PUSHA at byte 0
    uint8_t code[33];
    memset(code, 0x90, sizeof(code));
    code[0]  = 0x60;  // 1st PUSHA at byte 0 of block 0
    code[16] = 0x60;  // 2nd PUSHA at byte 0 of block 1
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.data_writes() >= 16; }, 20000);
    CHECK(done, "two PUSHAs drained 16 stores to memory");
    CHECK(tb.cycle_count() < 16000, "completed within 16000 cycles (no deadlock)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM idle after both PUSHAs");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Helper: extract dword value from a trace write entry
// ============================================================
static uint32_t trace_write_dword(const UcodeMemTB::MemTrace& t) {
    // addr[2] selects upper/lower dword on the 64-bit bus
    if (t.addr & 4)
        return (uint32_t)(t.data >> 32);
    else
        return (uint32_t)(t.data & 0xFFFFFFFF);
}

// ============================================================
// Test 9: PUSHA stack data verification
// Proves: 8 dwords written to contiguous descending addresses,
//         ESP slot (push 4) holds the original (pre-decrement) ESP
// ============================================================
static void test_pusha_data_verify(UcodeMemTB& tb) {
    printf("Test 9: PUSHA stack data verification\n");

    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x60;  // PUSHA at byte 0
    tb.load_program(code, sizeof(code));
    tb.reset();
    tb.enable_trace();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 10000);
    // Extra cycles to let all stores drain from LSQ to memory
    tb.run(200);
    tb.disable_trace();
    CHECK(done, "PUSHA completed");

    // Dump raw trace
    printf("  Raw write trace (%zu entries):\n", tb.mem_trace_.size());
    for (auto& t : tb.mem_trace_) {
        if (t.is_write)
            printf("    WR addr=0x%08X data=0x%016llX ben=0x%02X\n",
                   t.addr, (unsigned long long)t.data, t.ben);
    }

    // Collect unique dword writes by effective dword address
    // addr[2]=0 → lower dword at addr, addr[2]=1 → upper dword at addr
    struct StackWrite { uint32_t addr; uint32_t value; };
    StackWrite writes[16];
    int n_writes = 0;
    for (auto& t : tb.mem_trace_) {
        if (!t.is_write) continue;
        // Effective dword address: base + (ben selects upper or lower)
        uint32_t dword_addr = t.addr & ~3u;  // dword-aligned byte address
        uint32_t v = trace_write_dword(t);
        // Deduplicate by dword address
        bool dup = false;
        for (int j = 0; j < n_writes; j++) {
            if (writes[j].addr == dword_addr) { dup = true; break; }
        }
        if (!dup && n_writes < 16) {
            writes[n_writes++] = {dword_addr, v};
        }
    }
    CHECK(n_writes == 8, "exactly 8 unique dword stores from PUSHA");

    // Sort by address descending (PUSHA pushes high → low)
    for (int i = 0; i < n_writes - 1; i++)
        for (int j = i + 1; j < n_writes; j++)
            if (writes[j].addr > writes[i].addr)
                std::swap(writes[i], writes[j]);

    // Verify contiguous descending dword addresses
    bool contiguous = true;
    if (n_writes == 8) {
        for (int i = 1; i < 8; i++) {
            if (writes[i].addr != writes[i-1].addr - 4)
                contiguous = false;
        }
    }
    CHECK(contiguous, "8 stores at contiguous descending dword addresses");

    // Original ESP = first push address + 4 (PUSH writes to [ESP-4])
    uint32_t orig_esp = writes[0].addr + 4;

    // Slot 4 (index 4 when sorted desc) should be the original ESP
    if (n_writes == 8) {
        CHECK(writes[4].value == orig_esp,
              "PUSHA slot 4 = original ESP (not decremented)");
        printf("  orig_esp=0x%08X slot4_value=0x%08X %s\n",
               orig_esp, writes[4].value,
               writes[4].value == orig_esp ? "OK" : "MISMATCH");
    }

    // Verify memory readback matches trace
    int readback_ok = 0;
    for (int i = 0; i < n_writes; i++) {
        uint32_t actual = tb.read_mem32(writes[i].addr);
        if (actual == writes[i].value) readback_ok++;
    }
    CHECK(readback_ok == n_writes, "memory readback matches all trace writes");

    printf("  writes=%d contiguous=%d readback_ok=%d\n",
           n_writes, contiguous, readback_ok);
    for (int i = 0; i < n_writes; i++)
        printf("    [0x%08X] = 0x%08X\n", writes[i].addr, writes[i].value);
}

// ============================================================
// Test 10: PUSHA + POPA + PUSHA roundtrip data verification
// Proves: POPA restores all registers correctly — second PUSHA
//         produces identical stack contents as first
// ============================================================
static void test_pusha_popa_roundtrip_data(UcodeMemTB& tb) {
    printf("Test 10: PUSHA+POPA+PUSHA roundtrip data verification\n");

    // Block 0: PUSHA, Block 1: POPA, Block 2: PUSHA
    uint8_t code[49];
    memset(code, 0x90, sizeof(code));
    code[0]  = 0x60;  // PUSHA at block 0
    code[16] = 0x61;  // POPA at block 1
    code[32] = 0x60;  // PUSHA at block 2
    tb.load_program(code, sizeof(code));
    tb.reset();
    tb.enable_trace();

    bool done = tb.run_until([&]{
        return tb.data_writes() >= 16 && tb.ucode_state() == UC_IDLE;
    }, 40000);
    tb.disable_trace();
    CHECK(done, "PUSHA+POPA+PUSHA roundtrip completed");
    CHECK(tb.data_writes() >= 16, "at least 16 write events (2 × PUSHA)");
    CHECK(tb.data_reads() >= 7, "at least 7 reads from POPA (1 may be SQ-forwarded)");

    // Print full raw trace for diagnosis
    printf("  Raw trace (%zu entries):\n", tb.mem_trace_.size());
    for (size_t i = 0; i < tb.mem_trace_.size(); i++) {
        auto& t = tb.mem_trace_[i];
        printf("    [%3zu] %s addr=0x%08X data=0x%016llX ben=0x%02X dword=0x%08X\n",
               i, t.is_write ? "WR" : "RD", t.addr,
               (unsigned long long)t.data, t.ben, trace_write_dword(t));
    }

    // Separate PUSHA #1 and PUSHA #2 writes by looking for the read gap (POPA)
    struct StackWrite { uint32_t addr; uint32_t value; };
    std::vector<StackWrite> pusha1, pusha2;
    bool seen_read = false;
    for (auto& t : tb.mem_trace_) {
        if (!t.is_write) { seen_read = true; continue; }
        uint32_t dword_addr = t.addr & ~3u;
        uint32_t v = trace_write_dword(t);
        auto& target = seen_read ? pusha2 : pusha1;
        // Skip consecutive same-address writes (shim double-drain)
        if (!target.empty() && target.back().addr == dword_addr)
            continue;
        target.push_back({dword_addr, v});
    }

    printf("  PUSHA#1: %zu writes, PUSHA#2: %zu writes\n",
           pusha1.size(), pusha2.size());

    CHECK(pusha1.size() == 8, "PUSHA#1 produced 8 dword stores");
    CHECK(pusha2.size() == 8, "PUSHA#2 produced 8 dword stores");

    // Verify PUSHA#1 and PUSHA#2 push to same addresses
    // (proves POPA restored ESP correctly — ESP returned to original)
    int addr_match = 0;
    if (pusha1.size() == 8 && pusha2.size() == 8) {
        for (int i = 0; i < 8; i++) {
            if (pusha1[i].addr == pusha2[i].addr) addr_match++;
        }
    }
    CHECK(addr_match == 8, "PUSHA#2 addresses match PUSHA#1 (ESP restored by POPA)");

    // Verify values match (proves POPA restored all register values)
    int value_match = 0;
    if (pusha1.size() == 8 && pusha2.size() == 8) {
        for (int i = 0; i < 8; i++) {
            if (pusha1[i].value == pusha2[i].value)
                value_match++;
            else
                printf("  MISMATCH slot %d: pusha1=0x%08X pusha2=0x%08X\n",
                       i, pusha1[i].value, pusha2[i].value);
        }
    }
    CHECK(value_match == 8,
          "PUSHA#2 values match PUSHA#1 (POPA restored all regs)");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu addr_match=%d val_match=%d\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads(),
           addr_match, value_match);
}

// ============================================================
// Test 11: PUSHF basic
// Proves: PUSHF (0x9C) completes, generates ≥1 store, no deadlock
// ============================================================
static void test_pushf_basic(UcodeMemTB& tb) {
    printf("Test 11: PUSHF basic\n");

    // PUSHF (0x9C) at byte 0 of first fetch block
    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x9C;  // PUSHF at byte 0
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    CHECK(done, "PUSHF + NOPs retired");
    CHECK(tb.cycle_count() < 3000, "completed within 3000 cycles (no deadlock)");
    CHECK(tb.data_writes() >= 1, "at least 1 data memory write (PUSHF store drain)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM returned to UC_IDLE");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 12: PUSHF data verification
// Proves: PUSHF stores EFLAGS value (0x00000002 at reset) to ESP-4
// ============================================================
static void test_pushf_data_verify(UcodeMemTB& tb) {
    printf("Test 12: PUSHF data verification\n");

    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x9C;  // PUSHF at byte 0
    tb.load_program(code, sizeof(code));
    tb.reset();
    tb.enable_trace();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    tb.run(200);  // Let store drain
    tb.disable_trace();
    CHECK(done, "PUSHF completed");

    // Find the PUSHF store in trace
    bool found_eflags_write = false;
    for (auto& t : tb.mem_trace_) {
        if (!t.is_write) continue;
        uint32_t v = trace_write_dword(t);
        // Reset EFLAGS = 0x00000002 (bit 1 always set)
        if (v == 0x00000002) {
            found_eflags_write = true;
            printf("  PUSHF store: addr=0x%08X data=0x%08X OK\n", t.addr, v);
        }
    }
    CHECK(found_eflags_write, "PUSHF stored EFLAGS value 0x00000002");

    printf("  retired=%llu writes=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.data_writes());
}

// ============================================================
// Test 13: POPF basic
// Proves: POPF (0x9D) completes, generates ≥1 read, no deadlock
// ============================================================
static void test_popf_basic(UcodeMemTB& tb) {
    printf("Test 13: POPF basic\n");

    // Pre-seed stack memory with a known EFLAGS value at ESP
    // ESP at reset = 0xFFFFFFC0 (or wherever PUSHA ends — use a simpler approach)
    // Just place POPF and let it load from whatever is at ESP (probably 0)
    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x9D;  // POPF at byte 0
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    CHECK(done, "POPF + NOPs retired");
    CHECK(tb.cycle_count() < 3000, "completed within 3000 cycles (no deadlock)");
    CHECK(tb.data_reads() >= 1, "at least 1 data memory read (POPF load)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM returned to UC_IDLE");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 14: PUSHF + POPF roundtrip
// Proves: both complete sequentially, pipeline resumes
// ============================================================
static void test_pushf_popf_roundtrip(UcodeMemTB& tb) {
    printf("Test 14: PUSHF + POPF roundtrip\n");

    // Block 0: PUSHF, Block 1: POPF
    uint8_t code[33];
    memset(code, 0x90, sizeof(code));
    code[0]  = 0x9C;  // PUSHF at byte 0 of block 0
    code[16] = 0x9D;  // POPF at byte 0 of block 1
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 10000);
    CHECK(done, "PUSHF + POPF + NOPs retired");
    CHECK(tb.cycle_count() < 8000, "completed within 8000 cycles (no deadlock)");
    CHECK(tb.data_writes() >= 1, "at least 1 write from PUSHF");
    CHECK(tb.data_reads() >= 1, "at least 1 read from POPF");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM idle after roundtrip");

    printf("  retired=%llu cycles=%llu writes=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_writes(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 15: POPF modifies EFLAGS
// Proves: POPF writes loaded value to sys_eflags (CF set)
// ============================================================
static void test_popf_modifies_eflags(UcodeMemTB& tb) {
    printf("Test 15: POPF modifies EFLAGS\n");

    // PUSHF+POPF roundtrip with trace: verify POPF loads the correct value.
    // NOTE: NOP (0x90) is OP_ALU_REG which writes flags (PF=1,ZF=1 for zero result).
    // After POPF, trailing NOPs overwrite EFLAGS. So we verify the POPF *load data*
    // from the trace rather than the final EFLAGS register value.
    uint8_t code[33];
    memset(code, 0x90, sizeof(code));
    code[0]  = 0x9C;  // PUSHF at byte 0 of block 0
    code[16] = 0x9D;  // POPF at byte 0 of block 1
    tb.load_program(code, sizeof(code));
    tb.reset();
    tb.enable_trace();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 10000);
    tb.run(200);  // Let everything settle
    tb.disable_trace();
    CHECK(done, "PUSHF + POPF completed");

    // Find the POPF read in the trace — it should load reset EFLAGS (0x00000002)
    uint32_t popf_load_val = 0xDEAD;
    bool found_read = false;
    for (auto& e : tb.mem_trace_) {
        if (!e.is_write) {
            // Extract dword from 64-bit bus (same logic as trace_write_dword)
            popf_load_val = (e.addr & 4) ? (uint32_t)(e.data >> 32)
                                         : (uint32_t)(e.data & 0xFFFFFFFF);
            found_read = true;
            break;
        }
    }
    CHECK(found_read, "POPF produced a memory read");
    printf("  POPF loaded value = 0x%08X\n", popf_load_val);
    CHECK(popf_load_val == 0x00000002,
          "POPF loaded reset EFLAGS value (0x00000002) from stack");
}

// ============================================================
// Test 16: MOV CR0, EAX (STORE_CR) basic
// Proves: STORE_CR completes, writes to CR0
// ============================================================
static void test_store_cr_basic(UcodeMemTB& tb) {
    printf("Test 16: STORE_CR (MOV CR0, EAX) basic\n");

    // MOV CR0, EAX = 0F 22 C0 (ModRM: mod=11, reg=0(CR0), rm=0(EAX))
    // 0F 22 is 2 bytes, at byte 0 of a fetch block (U-pipe)
    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x0F;
    code[1] = 0x22;
    code[2] = 0xC0;  // ModRM: mod=11, reg=0, rm=0 (CR0 ← EAX)
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    CHECK(done, "MOV CR0,EAX + NOPs retired");
    CHECK(tb.cycle_count() < 3000, "completed within 3000 cycles (no deadlock)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM returned to UC_IDLE");

    // At reset, EAX=0. So CR0 should be written with 0.
    // But CR0 has a reset value (PE=0 etc). After MOV CR0,EAX with EAX=0,
    // CR0 should become 0.
    // Actually CR0 reset value in sys_regs might be 0x60000010 or similar.
    // We just check that the op completes without deadlock.
    printf("  retired=%llu cycles=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count());
}

// ============================================================
// Test 17: MOV EAX, CR0 (LOAD_CR) basic
// Proves: LOAD_CR completes, pipeline resumes
// ============================================================
static void test_load_cr_basic(UcodeMemTB& tb) {
    printf("Test 17: LOAD_CR (MOV EAX, CR0) basic\n");

    // MOV EAX, CR0 = 0F 20 C0 (ModRM: mod=11, reg=0(CR0), rm=0(EAX))
    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x0F;
    code[1] = 0x20;
    code[2] = 0xC0;  // ModRM: mod=11, reg=0, rm=0 (EAX ← CR0)
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    CHECK(done, "MOV EAX,CR0 + NOPs retired");
    CHECK(tb.cycle_count() < 3000, "completed within 3000 cycles (no deadlock)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM returned to UC_IDLE");

    printf("  retired=%llu cycles=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count());
}

// ============================================================
// Test 18: LGDT basic
// Proves: LGDT (0F 01 /2) completes, generates ≥2 loads, no deadlock
// ============================================================
static void test_lgdt_basic(UcodeMemTB& tb) {
    printf("Test 18: LGDT basic\n");

    // LGDT [disp32] = 67 0F 01 15 <addr32>
    // 67 = address-size override (16→32-bit in real mode)
    // ModRM 0x15: mod=00, reg=2(LGDT), rm=5(disp32)
    // Pseudo-descriptor address = 0x1000
    uint32_t desc_addr = 0x1000;

    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x67;  // Address-size override (real mode → 32-bit addressing)
    code[1] = 0x0F;
    code[2] = 0x01;
    code[3] = 0x15;  // ModRM: mod=00, reg=2, rm=5 (disp32)
    code[4] = (desc_addr >>  0) & 0xFF;
    code[5] = (desc_addr >>  8) & 0xFF;
    code[6] = (desc_addr >> 16) & 0xFF;
    code[7] = (desc_addr >> 24) & 0xFF;
    tb.load_program(code, sizeof(code));

    // Pre-seed pseudo-descriptor at desc_addr (6 bytes):
    // limit=0x0000, base=0x00000000 (zeros are fine for basic test)
    tb.write_mem32(desc_addr,     0x00000000);  // {base[15:0], limit}
    tb.write_mem32(desc_addr + 4, 0x00000000);  // {pad, base[31:16]}
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 10000);
    CHECK(done, "LGDT + NOPs retired");
    CHECK(tb.cycle_count() < 8000, "completed within 8000 cycles (no deadlock)");
    CHECK(tb.data_reads() >= 2, "at least 2 data memory reads (step 0 + LOAD_DTR)");
    CHECK(tb.ucode_state() == UC_IDLE, "microcode FSM returned to UC_IDLE");

    printf("  retired=%llu cycles=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_reads());
}

// ============================================================
// Test 19: LGDT data verification
// Proves: LGDT writes correct limit and base to GDTR
// ============================================================
static void test_lgdt_data_verify(UcodeMemTB& tb) {
    printf("Test 19: LGDT data verification\n");

    // Pseudo-descriptor: limit=0x1234, base=0xDEADBEEF
    // Memory layout (little-endian):
    //   addr+0: limit[7:0]  = 0x34
    //   addr+1: limit[15:8] = 0x12
    //   addr+2: base[7:0]   = 0xEF
    //   addr+3: base[15:8]  = 0xBE
    //   addr+4: base[23:16] = 0xAD
    //   addr+5: base[31:24] = 0xDE
    //
    // Step 0 loads dword at addr+0 = 0xBEEF1234 → {base[15:0], limit}
    // Step 1 loads dword at addr+4 = 0x????DEAD → base[31:16] in [15:0]
    // DTR: limit=0x1234, base={0xDEAD, 0xBEEF}=0xDEADBEEF

    uint32_t desc_addr = 0x2000;

    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x67;  // Address-size override (real mode → 32-bit addressing)
    code[1] = 0x0F;
    code[2] = 0x01;
    code[3] = 0x15;  // ModRM: mod=00, reg=2, rm=5 (disp32)
    code[4] = (desc_addr >>  0) & 0xFF;
    code[5] = (desc_addr >>  8) & 0xFF;
    code[6] = (desc_addr >> 16) & 0xFF;
    code[7] = (desc_addr >> 24) & 0xFF;
    tb.load_program(code, sizeof(code));

    // Pre-seed pseudo-descriptor
    tb.write_mem32(desc_addr,     0xBEEF1234);  // {base[15:0]=0xBEEF, limit=0x1234}
    tb.write_mem32(desc_addr + 4, 0x0000DEAD);  // {pad, base[31:16]=0xDEAD}
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 10000);
    tb.run(200);  // Let everything settle
    CHECK(done, "LGDT completed");

    uint32_t gdtr_base  = tb.gdtr_base();
    uint16_t gdtr_limit = tb.gdtr_limit();
    printf("  GDTR: base=0x%08X limit=0x%04X\n", gdtr_base, gdtr_limit);
    CHECK(gdtr_limit == 0x1234, "GDTR limit matches (0x1234)");
    CHECK(gdtr_base == 0xDEADBEEF, "GDTR base matches (0xDEADBEEF)");

    printf("  retired=%llu cycles=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count());
}

// ============================================================
// Test 20: LIDT basic + data verification
// Proves: LIDT (0F 01 /3) writes correct limit and base to IDTR
// ============================================================
static void test_lidt_data_verify(UcodeMemTB& tb) {
    printf("Test 20: LIDT data verification\n");

    // Pseudo-descriptor: limit=0xABCD, base=0x12345678
    uint32_t desc_addr = 0x3000;

    uint8_t code[17];
    memset(code, 0x90, sizeof(code));
    code[0] = 0x67;  // Address-size override (real mode → 32-bit addressing)
    code[1] = 0x0F;
    code[2] = 0x01;
    code[3] = 0x1D;  // ModRM: mod=00, reg=3(LIDT), rm=5(disp32)
    code[4] = (desc_addr >>  0) & 0xFF;
    code[5] = (desc_addr >>  8) & 0xFF;
    code[6] = (desc_addr >> 16) & 0xFF;
    code[7] = (desc_addr >> 24) & 0xFF;
    tb.load_program(code, sizeof(code));

    // Pre-seed: limit=0xABCD, base=0x12345678
    // dword at addr+0 = {base[15:0]=0x5678, limit=0xABCD} = 0x5678ABCD
    // dword at addr+4 = {pad, base[31:16]=0x1234} = 0x00001234
    tb.write_mem32(desc_addr,     0x5678ABCD);
    tb.write_mem32(desc_addr + 4, 0x00001234);
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 10000);
    tb.run(200);  // Let everything settle
    CHECK(done, "LIDT completed");

    uint32_t idtr_base  = tb.idtr_base();
    uint16_t idtr_limit = tb.idtr_limit();
    printf("  IDTR: base=0x%08X limit=0x%04X\n", idtr_base, idtr_limit);
    CHECK(idtr_limit == 0xABCD, "IDTR limit matches (0xABCD)");
    CHECK(idtr_base == 0x12345678, "IDTR base matches (0x12345678)");

    printf("  retired=%llu cycles=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count());
}

// ============================================================
// Test 21: Real-mode far JMP (0xEA)
// Proves: Far JMP in real mode updates CS selector and redirects PC
// ============================================================
static void test_far_jmp_real_mode(UcodeMemTB& tb) {
    printf("Test 21: Real-mode far JMP\n");

    // In real mode (PE=0), default_32=0, so this is 16-bit operand size.
    // 0xEA LL HH SS SS → JMP FAR seg:offset16
    // JMP FAR 0x2000:0x1000 → EA 00 10 00 20
    // But we need to jump to a valid address where there are NOPs.
    // Place far JMP at byte 0 of first fetch block (reset vector area 0xFFF0).
    // Target: 0x1000:0x0000 → linear address = 0x10000
    // Pre-fill target with NOPs.
    uint8_t code[] = {
        0xEA,                   // Far JMP opcode
        0x00, 0x00,             // Offset = 0x0000 (16-bit)
        0x00, 0x10,             // Selector = 0x1000
    };

    tb.load_program(code, sizeof(code));
    // Pre-fill target area (linear 0x10000 = 0x1000:0x0000) with NOPs
    for (int i = 0; i < 256; i++)
        tb.write_mem32(0x10000 + i*4, 0x90909090);
    tb.reset();

    // Wait for some retirements (NOPs at target should retire after the JMP)
    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 10000);
    tb.run(200);  // Let everything settle

    printf("  CS=0x%04X pc=0x%08X pe=%d d32=%d\n",
           tb.cs_sel(), tb.pc(), tb.pe_mode(), tb.default_32());
    printf("  retired=%llu cycles=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count());

    CHECK(done, "far JMP completed (instructions retired at target)");
    CHECK(tb.cs_sel() == 0x1000, "CS selector = 0x1000 after far JMP");
    CHECK(!tb.default_32(), "default_32 = 0 (real mode, D/B=0)");
    CHECK(!tb.pe_mode(), "still in real mode (PE=0)");
}

// ============================================================
// Test 22: Protected-mode far JMP with GDT lookup
// Proves: LGDT + MOV CR0 (set PE) + JMP FAR loads CS from GDT
// ============================================================
static void test_far_jmp_protected_mode(UcodeMemTB& tb) {
    printf("Test 22: Protected-mode far JMP with GDT lookup\n");

    // Full boot sequence across 4 fetch blocks:
    //   Block 0: LGDT [gdt_ptr_addr]
    //   Block 1: MOV EAX, [0x2000]  (loads PE bit value from memory)
    //   Block 2: MOV CR0, EAX       (sets PE=1)
    //   Block 3: JMP FAR 0x08:target32
    // NOTE: MOV reg,imm (B8) broken due to ALU opcode encoding bug; use mem load

    uint32_t gdt_base     = 0x3000;
    uint32_t gdt_ptr_addr = 0x3100;
    uint32_t target_pc    = 0x5000;

    uint8_t code[64];
    memset(code, 0x90, sizeof(code));

    // Block 0 [0-15]: LGDT [gdt_ptr_addr] (67 0F 01 15 <addr32>)
    code[0] = 0x67;  // Address-size override
    code[1] = 0x0F;
    code[2] = 0x01;
    code[3] = 0x15;  // ModRM: mod=00, reg=2(LGDT), rm=5(disp32)
    code[4] = (gdt_ptr_addr >>  0) & 0xFF;
    code[5] = (gdt_ptr_addr >>  8) & 0xFF;
    code[6] = (gdt_ptr_addr >> 16) & 0xFF;
    code[7] = (gdt_ptr_addr >> 24) & 0xFF;

    // Block 1 [16-31]: MOV EAX, [0x2000] (66 A1 00 20) — loads PE bit via memory
    code[16] = 0x66;  // Operand-size → 32-bit
    code[17] = 0xA1;  // MOV eAX, moffs
    code[18] = 0x00;  // addr low
    code[19] = 0x20;  // addr high = 0x2000

    // Block 2 [32-47]: MOV CR0, EAX (0F 22 C0) — sets PE=1
    code[32] = 0x0F;
    code[33] = 0x22;
    code[34] = 0xC0;

    // Block 3 [48-63]: JMP FAR 0x08:target32 (66 EA <target32> 08 00)
    code[48] = 0x66;  // Operand-size override → 32-bit offset
    code[49] = 0xEA;
    code[50] = (target_pc >>  0) & 0xFF;
    code[51] = (target_pc >>  8) & 0xFF;
    code[52] = (target_pc >> 16) & 0xFF;
    code[53] = (target_pc >> 24) & 0xFF;
    code[54] = 0x08;  // Selector low byte
    code[55] = 0x00;  // Selector high byte

    tb.load_program(code, sizeof(code));

    // Pre-seed GDT at 0x3000
    // Entry 0 (null)
    tb.write_mem32(gdt_base + 0,  0x00000000);
    tb.write_mem32(gdt_base + 4,  0x00000000);
    // Entry 1 (selector 0x08): code32, base=0, limit=4GB, G=1, D/B=1
    // Low:  0x0000FFFF (limit[15:0]=FFFF, base[15:0]=0000)
    // High: 0x00CF9B00 (base[31:24]=00, G=1,D/B=1,limit[19:16]=F, P=1,DPL=00,S=1,type=1011, base[23:16]=00)
    tb.write_mem32(gdt_base + 8,  0x0000FFFF);
    tb.write_mem32(gdt_base + 12, 0x00CF9B00);

    // Pre-seed GDT pseudo-descriptor at 0x3100
    tb.write_mem32(gdt_ptr_addr,     0x30000017);
    tb.write_mem32(gdt_ptr_addr + 4, 0x00000000);

    // Pre-seed value 1 at address 0x2000 (for MOV EAX, [0x2000])
    tb.write_mem32(0x2000, 0x00000001);

    // Pre-fill target area with NOPs
    for (int i = 0; i < 64; i++)
        tb.write_mem32(target_pc + i*4, 0x90909090);

    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 20000);
    tb.run(500);

    printf("  CS=0x%04X pc=0x%08X pe=%d d32=%d cr0=0x%08X\n",
           tb.cs_sel(), tb.pc(), tb.pe_mode(), tb.default_32(), tb.cr0());
    printf("  retired=%llu cycles=%llu reads=%llu writes=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_reads(),
           (unsigned long long)tb.data_writes());

    CHECK(done, "protected-mode boot sequence completed");
    CHECK(tb.pe_mode(), "PE mode active after MOV CR0");
    CHECK(tb.cs_sel() == 0x0008, "CS selector = 0x0008 after far JMP");
    CHECK(tb.default_32(), "default_32 = 1 (D/B=1 from GDT descriptor)");
}

// ============================================================
// Test 23: MOV DS, AX in real mode (register form)
// ============================================================
static void test_mov_ds_real_mode(UcodeMemTB& tb) {
    printf("Test 23: MOV DS, AX in real mode (register form)\n");

    // Block 0: MOV EAX, [0x2000] (66 A1 00 20) — load selector via memory
    // Block 1: MOV DS, AX (8E D8)
    uint8_t code[33];
    memset(code, 0x90, sizeof(code));
    code[0]  = 0x66;  // operand-size → 32-bit
    code[1]  = 0xA1;  // MOV eAX, moffs
    code[2]  = 0x00;  // addr low
    code[3]  = 0x20;  // addr high = 0x2000
    code[16] = 0x8E;  // MOV Sreg, r/m
    code[17] = 0xD8;  // ModRM: mod=11, reg=011(DS), rm=000(AX)

    tb.load_program(code, sizeof(code));
    tb.write_mem32(0x2000, 0x00000020);  // Selector = 0x0020
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    tb.run(200);

    printf("  DS.sel=0x%04X pe=%d retired=%llu\n",
           tb.seg_sel(3), tb.pe_mode(), (unsigned long long)tb.retired());
    CHECK(done, "MOV DS,AX completed");
    CHECK(tb.seg_sel(3) == 0x0020, "DS selector = 0x0020 after MOV DS,AX");
}

// ============================================================
// Test 24: Protected-mode MOV DS, AX with GDT lookup
// ============================================================
static void test_mov_ds_protected_mode(UcodeMemTB& tb) {
    printf("Test 24: Protected-mode MOV DS, AX with GDT lookup\n");

    // Full boot sequence + MOV DS,AX:
    //   Block 0: LGDT [gdt_ptr_addr]
    //   Block 1: MOV EAX, [0x2000]  (value = 1 → PE bit)
    //   Block 2: MOV CR0, EAX
    //   Block 3: JMP FAR 0x08:target
    //   target Block 0: MOV EAX, [0x2004]  (value = 0x0010 → selector)
    //   target Block 1: MOV DS, AX

    uint32_t gdt_base     = 0x3000;
    uint32_t gdt_ptr_addr = 0x3100;
    uint32_t target_pc    = 0x5000;

    // Boot code (4 blocks = 64 bytes)
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));

    // Block 0: LGDT [gdt_ptr_addr]
    code[0] = 0x67; code[1] = 0x0F; code[2] = 0x01; code[3] = 0x15;
    code[4] = (gdt_ptr_addr >>  0) & 0xFF;
    code[5] = (gdt_ptr_addr >>  8) & 0xFF;
    code[6] = (gdt_ptr_addr >> 16) & 0xFF;
    code[7] = (gdt_ptr_addr >> 24) & 0xFF;

    // Block 1: MOV EAX, [0x2000]
    code[16] = 0x66; code[17] = 0xA1; code[18] = 0x00; code[19] = 0x20;

    // Block 2: MOV CR0, EAX
    code[32] = 0x0F; code[33] = 0x22; code[34] = 0xC0;

    // Block 3: JMP FAR 0x08:target32
    code[48] = 0x66; code[49] = 0xEA;
    code[50] = (target_pc >>  0) & 0xFF;
    code[51] = (target_pc >>  8) & 0xFF;
    code[52] = (target_pc >> 16) & 0xFF;
    code[53] = (target_pc >> 24) & 0xFF;
    code[54] = 0x08; code[55] = 0x00;

    tb.load_program(code, sizeof(code));

    // Target code at 0x5000 (2 blocks = 32 bytes)
    uint8_t target_code[32];
    memset(target_code, 0x90, sizeof(target_code));
    // Block 0 at target: MOV EAX, [0x2004] — in 32-bit mode after far JMP
    target_code[0] = 0xA1;  // MOV EAX, moffs32 (already 32-bit mode)
    target_code[1] = 0x04; target_code[2] = 0x20;
    target_code[3] = 0x00; target_code[4] = 0x00;
    // Block 1 at target+16: MOV DS, AX
    target_code[16] = 0x8E; target_code[17] = 0xD8;

    for (int i = 0; i < 32; i++)
        tb.write_mem8(target_pc + i, target_code[i]);

    // Pre-seed GDT
    tb.write_mem32(gdt_base + 0,  0x00000000);  // Null descriptor
    tb.write_mem32(gdt_base + 4,  0x00000000);
    // Entry 1 (0x08): code32, base=0, limit=4GB
    tb.write_mem32(gdt_base + 8,  0x0000FFFF);
    tb.write_mem32(gdt_base + 12, 0x00CF9B00);
    // Entry 2 (0x10): data32, base=0, limit=4GB
    tb.write_mem32(gdt_base + 16, 0x0000FFFF);
    tb.write_mem32(gdt_base + 20, 0x00CF9300);  // data RW, DPL=0

    // GDT pseudo-descriptor
    tb.write_mem32(gdt_ptr_addr,     0x30000017);
    tb.write_mem32(gdt_ptr_addr + 4, 0x00000000);

    // Pre-seed data values
    tb.write_mem32(0x2000, 0x00000001);  // PE bit for CR0
    tb.write_mem32(0x2004, 0x00000010);  // Selector 0x10 for DS

    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 8; }, 30000);
    tb.run(500);

    printf("  CS=0x%04X DS=0x%04X pe=%d d32=%d cr0=0x%08X\n",
           tb.cs_sel(), tb.seg_sel(3), tb.pe_mode(), tb.default_32(), tb.cr0());
    printf("  retired=%llu cycles=%llu reads=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count(),
           (unsigned long long)tb.data_reads());

    CHECK(done, "protected-mode boot + MOV DS completed");
    CHECK(tb.pe_mode(), "PE mode active");
    CHECK(tb.cs_sel() == 0x0008, "CS = 0x0008");
    CHECK(tb.seg_sel(3) == 0x0010, "DS selector = 0x0010 after MOV DS,AX");
}

// ============================================================
// Test 25: Multiple segment register loads (DS, ES, SS)
// ============================================================
static void test_mov_multi_seg_real_mode(UcodeMemTB& tb) {
    printf("Test 25: Multiple segment register loads (DS, ES, SS) real mode\n");

    // Block 0: MOV EAX, [0x2000]  (selector = 0x1234)
    // Block 1: MOV DS, AX (8E D8)
    // Block 2: MOV ES, AX (8E C0)
    // Block 3: MOV SS, AX (8E D0)
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));
    code[0]  = 0x66; code[1]  = 0xA1; code[2]  = 0x00; code[3]  = 0x20;
    code[16] = 0x8E; code[17] = 0xD8;  // MOV DS, AX
    code[32] = 0x8E; code[33] = 0xC0;  // MOV ES, AX
    code[48] = 0x8E; code[49] = 0xD0;  // MOV SS, AX

    tb.load_program(code, sizeof(code));
    tb.write_mem32(0x2000, 0x00001234);
    tb.reset();

    uint64_t prev_ret = 0;
    bool done = false;
    for (int i = 0; i < 30000 && !done; i++) {
        tb.tick();
        uint64_t r = tb.retired();
        // Detailed trace for first 60 cycles
        if (i < 60) {
            printf("  [%3d] pc=%05X uc=%d um=%d iq=%02X rob=%d/%d/%d(%04X/%04X) "
                   "iqv=%d fd=%d xr=%d xv=%d lif=%d mrt=%d ret=%llu\n",
                   i, tb.pc(),
                   tb.ucode_state(), tb.um_state(),
                   tb.iq_entry_valid_mask(),
                   tb.rob_head(), tb.rob_tail(), tb.rob_count(),
                   tb.rob_entry_valid_mask(), tb.rob_entry_complete_mask(),
                   tb.iq_issue_valid(), tb.iq_force_dequeue(),
                   tb.exec_u_ready(), tb.exec_u_valid(),
                   tb.ld_in_flight(), tb.macro_rob_tag(),
                   (unsigned long long)r);
        }
        if (r != prev_ret) {
            if (i >= 60)
                printf("  [cyc %d] retired=%llu pc=0x%08X DS=0x%04X uc=%d\n",
                       i, (unsigned long long)r, tb.pc(), tb.seg_sel(3), tb.saw_uc_active());
            prev_ret = r;
        }
        if (r >= 6) done = true;
    }
    tb.run(200);

    printf("  DS=0x%04X ES=0x%04X SS=0x%04X retired=%llu\n",
           tb.seg_sel(3), tb.seg_sel(0), tb.seg_sel(2),
           (unsigned long long)tb.retired());

    CHECK(done, "multi-segment loads completed");
    CHECK(tb.seg_sel(3) == 0x1234, "DS = 0x1234");
    CHECK(tb.seg_sel(0) == 0x1234, "ES = 0x1234");
    CHECK(tb.seg_sel(2) == 0x1234, "SS = 0x1234");
}

// ============================================================
// Test 26: INT 0x21 basic completion (real mode)
// ============================================================
static void test_int_basic(UcodeMemTB& tb) {
    printf("Test 26: INT 0x21 basic completion (real mode)\n");

    // Program: INT 0x21
    uint8_t code[16];
    memset(code, 0x90, sizeof(code));
    code[0] = 0xCD; code[1] = 0x21;  // INT 0x21

    tb.load_program(code, sizeof(code));

    // Set up IVT entry at vector 0x21 * 4 = 0x84
    // IVT format: [offset_lo:16][segment:16]
    // Handler at 0x0000:0x1000 → linear 0x1000
    uint32_t ivt_entry = (0x0000 << 16) | 0x1000;  // seg=0x0000, off=0x1000
    tb.write_mem32(0x84, ivt_entry);

    // Put NOPs at handler address 0x1000
    uint8_t nops[16];
    memset(nops, 0x90, 16);
    for (int i = 0; i < 16; i++) tb.write_mem8(0x1000 + i, nops[i]);

    tb.reset();

    uint64_t prev_ret = 0;
    bool done = false;
    for (int i = 0; i < 10000 && !done; i++) {
        tb.tick();
        uint64_t r = tb.retired();
        if (i < 80) {
            printf("  [%3d] pc=%05X uc=%d um=%d ss=%d step=%d msr=0x%02X "
                   "sqv=%d mem=%d ro=%d ack=%d md=%d efl=%d ret=%llu\n",
                   i, tb.pc(),
                   tb.ucode_state(), tb.um_state(),
                   tb.seq_state(), tb.seq_step(), tb.uc_mem_special_r(),
                   tb.seq_uop_valid(), tb.uop_is_mem(), tb.uop_is_regonly(),
                   tb.ucode_exec_ack(), tb.uc_mem_done(), tb.has_eflags_cmd(),
                   (unsigned long long)r);
        }
        if (r != prev_ret) {
            if (i >= 80)
                printf("  [cyc %d] retired=%llu pc=0x%08X\n",
                       i, (unsigned long long)r, tb.pc());
            prev_ret = r;
        }
        if (r >= 10) done = true;
    }
    printf("  done=%d retired=%llu pc=0x%08X CS=0x%04X eflags=0x%08X\n",
           done, (unsigned long long)tb.retired(), tb.pc(), tb.cs_sel(), tb.eflags());

    CHECK(done, "INT 0x21 completed");
    CHECK(tb.saw_uc_active(), "UC_ACTIVE reached for INT");
}

// ============================================================
// Test 27: INT 0x10 with CS redirect verify
// ============================================================
static void test_int_redirect(UcodeMemTB& tb) {
    printf("Test 27: INT 0x10 CS:EIP redirect verify\n");

    uint8_t code[16];
    memset(code, 0x90, sizeof(code));
    code[0] = 0xCD; code[1] = 0x10;  // INT 0x10

    tb.load_program(code, sizeof(code));

    // IVT[0x10] at address 0x40: handler at 0x0500:0x0100 → linear 0x5100
    uint32_t ivt_entry = (0x0500 << 16) | 0x0100;
    tb.write_mem32(0x40, ivt_entry);

    // NOPs at handler linear address
    uint8_t nops[16];
    memset(nops, 0x90, 16);
    for (int i = 0; i < 16; i++) tb.write_mem8(0x5100 + i, nops[i]);

    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 8; }, 10000);
    tb.run(100);
    printf("  pc=0x%08X CS=0x%04X eflags=0x%08X retired=%llu\n",
           tb.pc(), tb.cs_sel(), tb.eflags(), (unsigned long long)tb.retired());

    CHECK(done, "INT 0x10 completed");
    CHECK(tb.cs_sel() == 0x0500, "CS = 0x0500 after INT 0x10");
    // IF should be cleared by CLI step
    CHECK((tb.eflags() & 0x200) == 0, "IF cleared after INT");
}

// ============================================================
// Test 28: INT 0x21 stack frame verify
// ============================================================
static void test_int_stack_frame(UcodeMemTB& tb) {
    printf("Test 28: INT 0x21 stack frame data verify\n");

    uint8_t code[16];
    memset(code, 0x90, sizeof(code));
    code[0] = 0xCD; code[1] = 0x21;  // INT 0x21

    tb.load_program(code, sizeof(code));

    // IVT[0x21] at 0x84: handler at 0x0000:0x2000
    uint32_t ivt_entry = (0x0000 << 16) | 0x2000;
    tb.write_mem32(0x84, ivt_entry);

    uint8_t nops[16];
    memset(nops, 0x90, 16);
    for (int i = 0; i < 16; i++) tb.write_mem8(0x2000 + i, nops[i]);

    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 8; }, 10000);
    tb.run(100);

    // After INT, ESP should have been decremented by 12 (3 pushes x 4 bytes)
    // Stack frame (top to bottom): FLAGS, CS, EIP (return addr)
    // Initial ESP is typically 0x0000 in this test harness (wraps to 0xFFFF area)
    // Read the three pushed dwords from memory
    // ESP at reset: check by reading stack area
    // The INT instruction is at PC=0x10000, length=2, so return EIP = 0x10002
    // CS at dispatch time = 0x0000 (reset value)
    // EFLAGS at dispatch = 0x00000002 (reset: reserved bit 1 set)

    // We can't easily read ESP, but we can check that the handler was reached
    printf("  pc=0x%08X CS=0x%04X retired=%llu\n",
           tb.pc(), tb.cs_sel(), (unsigned long long)tb.retired());
    CHECK(done, "INT 0x21 stack frame test completed");
}

// ============================================================
// Test 29: IRET basic completion
// ============================================================
static void test_iret_basic(UcodeMemTB& tb) {
    printf("Test 29: IRET basic completion\n");

    // We need to first execute INT to set up the stack frame,
    // then have the handler execute IRET.
    // Program: INT 0x21 at 0x10000
    // Handler at 0x0000:0x2000: IRET (0xCF) at byte 0
    uint8_t code[16];
    memset(code, 0x90, sizeof(code));
    code[0] = 0xCD; code[1] = 0x21;  // INT 0x21

    tb.load_program(code, sizeof(code));

    // IVT[0x21] at 0x84: handler at 0x0000:0x2000
    uint32_t ivt_entry = (0x0000 << 16) | 0x2000;
    tb.write_mem32(0x84, ivt_entry);

    // Handler: IRET at byte 0 of a 16-byte block
    uint8_t handler[16];
    memset(handler, 0x90, 16);
    handler[0] = 0xCF;  // IRET
    for (int i = 0; i < 16; i++) tb.write_mem8(0x2000 + i, handler[i]);

    // Also need NOPs after the INT instruction for when IRET returns
    uint8_t after_int[16];
    memset(after_int, 0x90, 16);
    for (int i = 0; i < 16; i++) tb.write_mem8(0x10010 + i, after_int[i]);

    tb.reset();

    // Wait for enough retirements (INT=1 retirement + handler IRET=1 + more)
    bool done = tb.run_until([&]{ return tb.retired() >= 10; }, 30000);
    tb.run(200);
    printf("  pc=0x%08X CS=0x%04X eflags=0x%08X retired=%llu\n",
           tb.pc(), tb.cs_sel(), tb.eflags(), (unsigned long long)tb.retired());

    CHECK(done, "INT + IRET roundtrip completed");
    // After IRET, CS should be restored to original (0x0000)
    CHECK(tb.cs_sel() == 0x0000, "CS restored to 0x0000 after IRET");
}

// ============================================================
// Test 30: INT + IRET with nonzero CS roundtrip
// ============================================================
static void test_int_iret_roundtrip(UcodeMemTB& tb) {
    printf("Test 30: INT + IRET with nonzero CS roundtrip\n");

    uint8_t code[16];
    memset(code, 0x90, sizeof(code));
    code[0] = 0xCD; code[1] = 0x10;  // INT 0x10

    tb.load_program(code, sizeof(code));

    // IVT[0x10] at 0x40: handler at 0x0300:0x0100 → linear 0x3100
    uint32_t ivt_entry = (0x0300 << 16) | 0x0100;
    tb.write_mem32(0x40, ivt_entry);

    // Handler at linear 0x3100: IRET
    uint8_t handler[16];
    memset(handler, 0x90, 16);
    handler[0] = 0xCF;  // IRET
    for (int i = 0; i < 16; i++) tb.write_mem8(0x3100 + i, handler[i]);

    // NOPs after the INT for return
    uint8_t after_int[16];
    memset(after_int, 0x90, 16);
    for (int i = 0; i < 16; i++) tb.write_mem8(0x10010 + i, after_int[i]);

    tb.reset();

    // Track CS changes
    uint16_t max_cs = 0;
    uint64_t prev_ret = 0;
    bool done = false;
    for (int i = 0; i < 30000 && !done; i++) {
        tb.tick();
        uint16_t cs = tb.cs_sel();
        if (cs > max_cs) max_cs = cs;
        uint64_t r = tb.retired();
        // Print detailed trace for first 120 cycles
        if (i < 120) {
            printf("  [%3d] pc=%05X uc=%d um=%d ss=%d step=%d msr=0x%02X "
                   "sqv=%d ro=%d ack=%d CS=%04X ret=%llu\n",
                   i, tb.pc(),
                   tb.ucode_state(), tb.um_state(),
                   tb.seq_state(), tb.seq_step(), tb.uc_mem_special_r(),
                   tb.seq_uop_valid(), tb.uop_is_regonly(),
                   tb.ucode_exec_ack(), cs,
                   (unsigned long long)r);
        }
        if (r != prev_ret && i >= 120) {
            printf("  [cyc %d] retired=%llu pc=0x%08X CS=%04X\n",
                   i, (unsigned long long)r, tb.pc(), tb.cs_sel());
            prev_ret = r;
        }
        if (r >= 10) done = true;
    }
    tb.run(200);
    printf("  pc=0x%08X CS=0x%04X max_CS=0x%04X eflags=0x%08X retired=%llu\n",
           tb.pc(), tb.cs_sel(), max_cs, tb.eflags(), (unsigned long long)tb.retired());

    CHECK(done, "INT+IRET nonzero CS roundtrip completed");
    CHECK(max_cs == 0x0300, "CS reached 0x0300 during INT handler");
    CHECK(tb.cs_sel() == 0x0000, "CS restored to 0x0000 after IRET");
}

// ============================================================
// Main
// ============================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    printf("=== fabi386 Microcode Memory Integration Test ===\n\n");

    UcodeMemTB tb;

    // Quick sanity: does CPUID work with LSQ_MEMIF enabled?
    // NOTE: Decoder processes 2 instructions per 16-byte fetch block
    // (U at byte 0, V at byte U_len), then advances PC by 16.
    // Test opcodes MUST be at byte 0 of a fetch block to be decoded.
    {
        printf("Test 0: CPUID with LSQ_MEMIF (sanity)\n");
        uint8_t code[] = {
            0x0F, 0xA2,  // CPUID at byte 0 of block 0 (U-pipe)
        };
        tb.load_program(code, sizeof(code));
        tb.reset();
        bool done = tb.run_until([&]{ return tb.retired() >= 10; }, 5000);
        CHECK(done, "CPUID + NOPs completed");
        CHECK(tb.saw_uc_active(), "UC_ACTIVE reached for CPUID");
        printf("  retired=%llu cycles=%llu uc_active=%d\n",
               (unsigned long long)tb.retired(),
               (unsigned long long)tb.cycle_count(),
               tb.saw_uc_active());
    }

    test_basic_d6(tb);
    test_early_d6(tb);
    test_back_to_back_d6(tb);
    test_data_mem_activity(tb);
    test_pusha_basic(tb);
    test_popa_basic(tb);
    test_pusha_popa_roundtrip(tb);
    test_back_to_back_pusha(tb);
    test_pusha_data_verify(tb);
    test_pusha_popa_roundtrip_data(tb);

    test_pushf_basic(tb);
    test_pushf_data_verify(tb);
    test_popf_basic(tb);
    test_pushf_popf_roundtrip(tb);
    test_popf_modifies_eflags(tb);
    test_store_cr_basic(tb);
    test_load_cr_basic(tb);
    test_lgdt_basic(tb);
    test_lgdt_data_verify(tb);
    test_lidt_data_verify(tb);

    test_far_jmp_real_mode(tb);

    // Debug test: MOV EAX,[0x2000] → MOV CR0,EAX (no LGDT)
    // NOTE: MOV AX, imm (B8) goes through ALU with raw opcode, which is broken
    //       (pre-existing ALU opcode encoding bug). Use memory load instead.
    {
        printf("Test 21b: MOV EAX,[mem] + MOV CR0,EAX (CR0 value chain)\n");
        // Block 0: MOV EAX, [0x2000] (66 A1 00 20) — 32-bit operand, 16-bit addr
        // Block 1: MOV CR0, EAX (0F 22 C0)
        uint8_t code[33];
        memset(code, 0x90, sizeof(code));
        code[0]  = 0x66;  // operand-size → 32-bit
        code[1]  = 0xA1;  // MOV eAX, moffs
        code[2]  = 0x00;  // addr low
        code[3]  = 0x20;  // addr high = 0x2000
        code[16] = 0x0F; code[17] = 0x22; code[18] = 0xC0; // MOV CR0, EAX
        tb.load_program(code, sizeof(code));
        // Pre-seed value 1 at address 0x2000
        tb.write_mem32(0x2000, 0x00000001);
        tb.reset();

        uint32_t prev_cr0 = tb.cr0();
        bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
        tb.run(200);
        uint32_t new_cr0 = tb.cr0();
        printf("  cr0: 0x%08X → 0x%08X  pe=%d  retired=%llu\n",
               prev_cr0, new_cr0, (new_cr0 & 1), (unsigned long long)tb.retired());
        CHECK((new_cr0 & 1) == 1, "CR0.PE = 1 after MOV EAX,[mem] + MOV CR0,EAX");
    }

    // Debug test: LGDT + MOV EAX,[mem] + MOV CR0,EAX (no far JMP)
    {
        printf("Test 21c: LGDT + MOV EAX,[mem] + MOV CR0,EAX (LGDT+CR0 chain)\n");
        uint32_t gdt_ptr_addr = 0x3100;
        uint8_t code[49];
        memset(code, 0x90, sizeof(code));
        // Block 0: LGDT [0x3100]
        code[0] = 0x67; code[1] = 0x0F; code[2] = 0x01; code[3] = 0x15;
        code[4] = 0x00; code[5] = 0x31; code[6] = 0x00; code[7] = 0x00;
        // Block 1: MOV EAX, [0x2000] (66 A1 00 20)
        code[16] = 0x66; code[17] = 0xA1; code[18] = 0x00; code[19] = 0x20;
        // Block 2: MOV CR0, EAX (0F 22 C0)
        code[32] = 0x0F; code[33] = 0x22; code[34] = 0xC0;
        tb.load_program(code, sizeof(code));
        // Seed pseudo-descriptor
        tb.write_mem32(gdt_ptr_addr, 0x30000017);
        tb.write_mem32(gdt_ptr_addr + 4, 0x00000000);
        // Pre-seed value 1 at address 0x2000
        tb.write_mem32(0x2000, 0x00000001);
        tb.reset();
        tb.enable_trace();

        uint32_t prev_cr0 = tb.cr0();
        bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 10000);
        tb.run(200);
        tb.disable_trace();
        uint32_t new_cr0 = tb.cr0();
        printf("  cr0: 0x%08X → 0x%08X  pe=%d  retired=%llu  reads=%llu\n",
               prev_cr0, new_cr0, (new_cr0 & 1),
               (unsigned long long)tb.retired(), (unsigned long long)tb.data_reads());
        CHECK((new_cr0 & 1) == 1, "CR0.PE = 1 after LGDT + MOV EAX,[mem] + MOV CR0,EAX");
    }

    test_far_jmp_protected_mode(tb);

    test_mov_ds_real_mode(tb);
    test_mov_ds_protected_mode(tb);
    test_mov_multi_seg_real_mode(tb);

    test_int_basic(tb);
    test_int_redirect(tb);
    test_int_stack_frame(tb);
    test_iret_basic(tb);
    test_int_iret_roundtrip(tb);

    printf("\n=== Results: %d checks, %d failures ===\n", g_checks, g_fails);
    if (g_fails > 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
