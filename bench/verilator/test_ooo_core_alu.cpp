/*
 * fabi386: ALU Opcode Encoding Test (P3.ALU)
 * -------------------------------------------
 * Verifies the ALU opcode re-encoding fix in the decoder.
 * Each test places instructions in fetch memory, runs the pipeline,
 * and verifies results via EFLAGS (CMP-based verification pattern).
 *
 * No VERILATOR_ENABLE_* defines needed — uses default gate configuration.
 *
 * Tests:
 *   1.  MOV AX, imm — bypass path (immediate passthrough)
 *   2.  ADD AX, imm — ALU add with proper encoding
 *   3.  XOR AX, AX  — zero result, ZF set
 *   4.  INC AX      — increment, CMP verify
 *   5.  CMP AX, imm — flags only, no writeback
 *   6.  SHL AX, imm — shift left
 *   7.  NOT AX      — bitwise NOT, no flag write
 *   8.  NEG AX      — negation, flags set
 *   9.  MOV CX, AX  — register-to-register bypass
 *  10.  DEC AX      — decrement to zero, ZF set
 */

#include <cstdlib>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <memory>

#include "Vf386_ooo_core_top.h"
#include "Vf386_ooo_core_top___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "memory_model.h"

static int g_checks = 0;
static int g_fails  = 0;

#define CHECK(cond, msg) do {                                 \
    g_checks++;                                               \
    if (!(cond)) {                                            \
        printf("  FAIL: %s (line %d)\n", msg, __LINE__);     \
        g_fails++;                                            \
    }                                                         \
} while(0)

// EFLAGS bit positions (match f386_pkg.sv)
static constexpr uint32_t EFLAGS_CF = (1 << 0);
static constexpr uint32_t EFLAGS_ZF = (1 << 6);
static constexpr uint32_t EFLAGS_SF = (1 << 7);

class AluTB {
public:
    AluTB()
        : top_(std::make_unique<Vf386_ooo_core_top>())
        , trace_(std::make_unique<VerilatedVcdC>())
        , cycle_(0)
        , retired_(0)
        , trace_time_(0)
    {
        Verilated::traceEverOn(true);
        top_->trace(trace_.get(), 99);
        trace_->open("tb_ooo_core_alu.vcd");
    }

    ~AluTB() {
        trace_->close();
    }

    // Load a program at the reset vector.
    // Each instruction should be placed at byte 0 of a 16-byte-aligned block.
    // Helper: place instruction bytes at block N (offset = N * 16).
    void load_program(const uint8_t* code, size_t len, uint32_t base = 0xFFF0) {
        mem_.fill(base, 4096, 0x90);  // Large NOP background to prevent garbage fetch
        for (size_t i = 0; i < len; i++)
            mem_.write8(base + i, code[i]);
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
        top_->io_port_rdata = 0;
        top_->io_port_ack = 0;
        top_->pt_rdata = 0;
        top_->pt_ack = 0;
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
    }

    void tick() {
        top_->clk = 1;
        top_->eval();
        trace_->dump(trace_time_++);

        service_fetch();
        service_data_mem();

        if (top_->trace_valid)
            retired_++;

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

    void run(uint64_t n) {
        for (uint64_t i = 0; i < n; i++) tick();
    }

    uint64_t retired()     const { return retired_; }
    uint64_t cycle_count() const { return cycle_; }

    uint32_t eflags() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_eflags;
    }

    uint32_t pc() const {
        return top_->rootp->f386_ooo_core_top__DOT__pc_current;
    }


private:
    std::unique_ptr<Vf386_ooo_core_top> top_;
    std::unique_ptr<VerilatedVcdC>      trace_;
    MemoryModel                         mem_;
    uint64_t                            cycle_;
    uint64_t                            retired_;
    uint64_t                            trace_time_;

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
        // Simple ack for any data memory request (should not be needed for ALU tests)
        if (top_->mem_req) {
            uint32_t addr = top_->mem_addr;
            if (!top_->mem_wr) {
                top_->mem_rdata = mem_.read32(addr);
            }
            top_->mem_ack = 1;
            top_->mem_gnt = 1;
        } else {
            top_->mem_ack = 0;
            top_->mem_gnt = 0;
        }
    }
};

// Helper: place an instruction at block N within a code buffer
// block_size = 16 bytes per fetch block
static void place_at_block(uint8_t* buf, int block, const uint8_t* instr, size_t len) {
    memcpy(buf + block * 16, instr, len);
}

// ============================================================
// Test 1: MOV AX, 0x1234 (bypass) + CMP verify
// ============================================================
static void test_mov_imm(AluTB& tb) {
    printf("Test 1: MOV AX, 0x1234 (bypass path)\n");

    // Block 0: MOV AX, 0x1234 (B8 34 12) — 3 bytes
    // Block 1: CMP AX, 0x1234 (3D 34 12) — 3 bytes
    uint8_t code[48];
    memset(code, 0x90, sizeof(code));
    uint8_t mov_ax[] = {0xB8, 0x34, 0x12};
    uint8_t cmp_ax[] = {0x3D, 0x34, 0x12};
    place_at_block(code, 0, mov_ax, 3);
    place_at_block(code, 1, cmp_ax, 3);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);  // Let flags commit

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after CMP AX,0x1234 (MOV bypass correct)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 2: ADD AX, 5 (after MOV AX, 10)
// ============================================================
static void test_add_imm(AluTB& tb) {
    printf("Test 2: ADD AX, 5 (ALU add)\n");

    // Block 0: MOV AX, 10 (B8 0A 00)
    // Block 1: ADD AX, 5  (05 05 00) — ADD AX, imm16
    // Block 2: CMP AX, 15 (3D 0F 00)
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));
    uint8_t mov[]  = {0xB8, 0x0A, 0x00};
    uint8_t add[]  = {0x05, 0x05, 0x00};
    uint8_t cmp[]  = {0x3D, 0x0F, 0x00};
    place_at_block(code, 0, mov, 3);
    place_at_block(code, 1, add, 3);
    place_at_block(code, 2, cmp, 3);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after CMP AX,15 (ADD result correct)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 3: XOR AX, AX → zero result, ZF set
// ============================================================
static void test_xor_self(AluTB& tb) {
    printf("Test 3: XOR AX, AX (zero + ZF)\n");

    // Block 0: MOV AX, 0xFFFF (B8 FF FF) — set to nonzero first
    // Block 1: XOR AX, AX (31 C0) — result = 0
    //   31 = XOR r/m16, r16: mod=11, reg=AX(0), rm=AX(0) → ModRM=C0
    uint8_t code[48];
    memset(code, 0x90, sizeof(code));
    uint8_t mov[] = {0xB8, 0xFF, 0xFF};
    uint8_t xor_[] = {0x31, 0xC0};
    place_at_block(code, 0, mov, 3);
    place_at_block(code, 1, xor_, 2);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after XOR AX,AX");
    CHECK((ef & EFLAGS_CF) == 0, "CF clear after XOR");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 4: INC AX (verify via CMP)
// ============================================================
static void test_inc(AluTB& tb) {
    printf("Test 4: INC AX\n");

    // Block 0: MOV AX, 0x000A (B8 0A 00)
    // Block 1: INC AX (40) — AX = 0x000B
    // Block 2: CMP AX, 0x000B (3D 0B 00)
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));
    uint8_t mov[] = {0xB8, 0x0A, 0x00};
    uint8_t inc[] = {0x40};
    uint8_t cmp[] = {0x3D, 0x0B, 0x00};
    place_at_block(code, 0, mov, 3);
    place_at_block(code, 1, inc, 1);
    place_at_block(code, 2, cmp, 3);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after CMP AX,11 (INC result correct)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 5: CMP AX, imm (flags only, no writeback)
// ============================================================
static void test_cmp_flags(AluTB& tb) {
    printf("Test 5: CMP AX, imm (flags, no writeback)\n");

    // Block 0: MOV AX, 10 (B8 0A 00)
    // Block 1: CMP AX, 10 (3D 0A 00) — ZF should be set
    // Block 2: CMP AX, 10 (3D 0A 00) — ZF still set (AX unchanged by first CMP)
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));
    uint8_t mov[]  = {0xB8, 0x0A, 0x00};
    uint8_t cmp1[] = {0x3D, 0x0A, 0x00};
    uint8_t cmp2[] = {0x3D, 0x0A, 0x00};
    place_at_block(code, 0, mov, 3);
    place_at_block(code, 1, cmp1, 3);
    place_at_block(code, 2, cmp2, 3);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    // Second CMP should also produce ZF=1 (AX not modified by first CMP)
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after second CMP (no writeback verified)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 6: SHL AX, 4
// ============================================================
static void test_shl(AluTB& tb) {
    printf("Test 6: SHL AX, 4\n");

    // Block 0: MOV AX, 1 (B8 01 00)
    // Block 1: SHL AX, 4 (C1 E0 04) — C1 /4 (reg=4, rm=AX → E0), imm8=4
    // Block 2: CMP AX, 16 (3D 10 00) — 1 << 4 = 16
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));
    uint8_t mov[] = {0xB8, 0x01, 0x00};
    uint8_t shl[] = {0xC1, 0xE0, 0x04};
    uint8_t cmp[] = {0x3D, 0x10, 0x00};
    place_at_block(code, 0, mov, 3);
    place_at_block(code, 1, shl, 3);
    place_at_block(code, 2, cmp, 3);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after CMP AX,16 (SHL result correct)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 7: NOT AX (no flags written)
// ============================================================
static void test_not(AluTB& tb) {
    printf("Test 7: NOT AX\n");

    // Block 0: MOV AX, 0x00FF (B8 FF 00)
    // Block 1: NOT AX (F7 D0) — F7 /2 (reg=2, rm=AX → mod=11, reg=2, rm=0 → D0)
    // Block 2: CMP AX, 0xFF00 (3D 00 FF)
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));
    uint8_t mov[] = {0xB8, 0xFF, 0x00};
    uint8_t not_[] = {0xF7, 0xD0};
    uint8_t cmp[] = {0x3D, 0x00, 0xFF};
    place_at_block(code, 0, mov, 3);
    place_at_block(code, 1, not_, 2);
    place_at_block(code, 2, cmp, 3);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after CMP AX,0xFF00 (NOT result correct)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 8: NEG AX
// ============================================================
static void test_neg(AluTB& tb) {
    printf("Test 8: NEG AX\n");

    // Block 0: MOV AX, 5 (B8 05 00)
    // Block 1: NEG AX (F7 D8) — F7 /3 (reg=3, rm=AX → mod=11, reg=3, rm=0 → D8)
    //   Result: 0 - 5 = 0xFFFB (16-bit: -5)
    // Block 2: CMP AX, 0xFFFB (3D FB FF)
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));
    uint8_t mov[] = {0xB8, 0x05, 0x00};
    uint8_t neg[] = {0xF7, 0xD8};
    uint8_t cmp[] = {0x3D, 0xFB, 0xFF};
    place_at_block(code, 0, mov, 3);
    place_at_block(code, 1, neg, 2);
    place_at_block(code, 2, cmp, 3);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after CMP AX,0xFFFB (NEG result correct)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 9: MOV CX, AX (register-to-register bypass)
// ============================================================
static void test_mov_reg(AluTB& tb) {
    printf("Test 9: MOV CX, AX (reg-to-reg bypass)\n");

    // Block 0: MOV AX, 0x5678 (B8 78 56)
    // Block 1: MOV CX, AX (89 C1) — 89 = MOV r/m16, r16: mod=11, reg=AX(0), rm=CX(1) → C1
    // Block 2: CMP CX, 0x5678 (81 F9 78 56)
    //   81 = Grp1 r/m16, imm16: reg=7(CMP), rm=CX(1) → mod=11, reg=7, rm=1 → F9
    uint8_t code[64];
    memset(code, 0x90, sizeof(code));
    uint8_t mov_ax[]  = {0xB8, 0x78, 0x56};
    uint8_t mov_cx[]  = {0x89, 0xC1};
    uint8_t cmp_cx[]  = {0x81, 0xF9, 0x78, 0x56};
    place_at_block(code, 0, mov_ax, 3);
    place_at_block(code, 1, mov_cx, 2);
    place_at_block(code, 2, cmp_cx, 4);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 6; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after CMP CX,0x5678 (MOV reg,reg correct)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Test 10: DEC AX to zero (ZF)
// ============================================================
static void test_dec_zero(AluTB& tb) {
    printf("Test 10: DEC AX (to zero)\n");

    // Block 0: MOV AX, 1 (B8 01 00)
    // Block 1: DEC AX (48) — AX = 0, ZF set
    uint8_t code[48];
    memset(code, 0x90, sizeof(code));
    uint8_t mov[] = {0xB8, 0x01, 0x00};
    uint8_t dec[] = {0x48};
    place_at_block(code, 0, mov, 3);
    place_at_block(code, 1, dec, 1);
    tb.load_program(code, sizeof(code));
    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 5000);
    CHECK(done, "retired enough instructions");
    tb.run(50);

    uint32_t ef = tb.eflags();
    CHECK((ef & EFLAGS_ZF) != 0, "ZF set after DEC AX (1 → 0)");
    printf("  eflags=0x%08X retired=%llu\n", ef, (unsigned long long)tb.retired());
}

// ============================================================
// Main
// ============================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    printf("=== fabi386 ALU Opcode Encoding Test (P3.ALU) ===\n\n");

    AluTB tb;

    test_mov_imm(tb);
    test_add_imm(tb);
    test_xor_self(tb);
    test_inc(tb);
    test_cmp_flags(tb);
    test_shl(tb);
    test_not(tb);
    test_neg(tb);
    test_mov_reg(tb);
    test_dec_zero(tb);

    printf("\n=== Results: %d checks, %d failures ===\n", g_checks, g_fails);

    if (g_fails > 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
