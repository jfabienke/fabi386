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
#include <memory>

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
    }

    void tick() {
        // Rising edge
        top_->clk = 1;
        top_->eval();
        trace_->dump(trace_time_++);

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

    uint64_t retired()      const { return retired_; }
    uint64_t cycle_count()  const { return cycle_; }
    uint64_t data_writes()  const { return data_writes_; }
    uint64_t data_reads()   const { return data_reads_; }

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
        if (top_->mem_req) {
            uint32_t addr = top_->mem_addr;
            if (top_->mem_wr) {
                uint64_t wdata = top_->mem_wdata;
                uint8_t  ben   = top_->mem_byte_en;
                for (int i = 0; i < 8; i++) {
                    if (ben & (1 << i))
                        mem_.write8(addr + i, (wdata >> (i * 8)) & 0xFF);
                }
                data_writes_++;
            } else {
                uint64_t rdata = 0;
                for (int i = 0; i < 8; i++)
                    rdata |= (uint64_t)mem_.read8(addr + i) << (i * 8);
                top_->mem_rdata = rdata;
                data_reads_++;
            }
            top_->mem_ack = 1;
        } else {
            top_->mem_ack = 0;
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

    printf("\n=== Results: %d checks, %d failures ===\n", g_checks, g_fails);
    if (g_fails > 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
