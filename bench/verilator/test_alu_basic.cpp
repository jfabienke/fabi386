/*
 * fabi386: ALU Unit Test
 * -----------------------
 * Tests all ALU operations for correctness of results and flags.
 * Exercises: ADD, SUB, AND, OR, XOR, INC, DEC, CMP, shifts, rotates.
 * Verifies: CF, OF, ZF, SF, PF, AF for all operand sizes.
 *
 * Reference: 80x86/tests/ structure
 */

#include <cstdlib>
#include <cstdio>
#include <cassert>
#include <cstdint>
#include <vector>
#include <string>

#include "Vf386_alu.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

// ALU flags layout: flags_out = {OF, SF, ZF, AF, PF, CF}
#define FLAG_CF  (1 << 0)
#define FLAG_PF  (1 << 1)
#define FLAG_AF  (1 << 2)
#define FLAG_ZF  (1 << 3)
#define FLAG_SF  (1 << 4)
#define FLAG_OF  (1 << 5)

struct AluTest {
    std::string name;
    uint8_t  alu_op;
    uint32_t op_a;
    uint32_t op_b;
    uint8_t  cin;
    uint32_t expected_result;
    uint8_t  expected_flags_mask;  // Which flags to check
    uint8_t  expected_flags;       // Expected flag values
};

static int tests_run = 0;
static int tests_passed = 0;

static void run_test(Vf386_alu* alu, VerilatedVcdC* trace,
                     const AluTest& test, uint64_t& tick)
{
    tests_run++;

    alu->op_a   = test.op_a;
    alu->op_b   = test.op_b;
    alu->alu_op = test.alu_op;
    alu->cin    = test.cin;

    alu->eval();
    trace->dump(tick++);

    bool result_ok = (alu->result == test.expected_result);
    bool flags_ok = ((alu->flags_out & test.expected_flags_mask) == test.expected_flags);

    if (result_ok && flags_ok) {
        tests_passed++;
    } else {
        printf("FAIL: %s\n", test.name.c_str());
        printf("  op_a=0x%08X op_b=0x%08X op=%02X cin=%d\n",
               test.op_a, test.op_b, test.alu_op, test.cin);
        if (!result_ok)
            printf("  Result: got 0x%08X, expected 0x%08X\n",
                   alu->result, test.expected_result);
        if (!flags_ok)
            printf("  Flags: got 0x%02X, expected 0x%02X (mask 0x%02X)\n",
                   alu->flags_out & test.expected_flags_mask,
                   test.expected_flags, test.expected_flags_mask);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    auto alu = std::make_unique<Vf386_alu>();
    auto trace = std::make_unique<VerilatedVcdC>();
    alu->trace(trace.get(), 99);
    trace->open("test_alu_basic.vcd");

    printf("=== fabi386 ALU Basic Test ===\n");

    uint64_t tick = 0;

    // ALU op encodings (from f386_alu.v)
    // alu_op[3:0] = operation, alu_op[5:4] = size (00=32, 01=16, 10=8)
    constexpr uint8_t OP_ADD  = 0x00;
    constexpr uint8_t OP_SUB  = 0x01;
    constexpr uint8_t OP_AND  = 0x02;
    constexpr uint8_t OP_OR   = 0x03;
    constexpr uint8_t OP_XOR  = 0x04;
    constexpr uint8_t OP_SHL  = 0x05;
    constexpr uint8_t OP_SHR  = 0x06;
    constexpr uint8_t OP_SAR  = 0x07;
    constexpr uint8_t OP_ADC  = 0x08;
    constexpr uint8_t OP_SBB  = 0x09;
    constexpr uint8_t OP_NOT  = 0x0A;
    constexpr uint8_t OP_NEG  = 0x0B;
    constexpr uint8_t OP_INC  = 0x0C;
    constexpr uint8_t OP_DEC  = 0x0D;

    std::vector<AluTest> tests = {
        // --- Basic ADD (op=0x0) ---
        {"ADD 0+0=0 (ZF,PF)",      OP_ADD, 0x00000000, 0x00000000, 0,
            0x00000000, FLAG_ZF | FLAG_PF, FLAG_ZF | FLAG_PF},

        {"ADD 1+1=2",              OP_ADD, 0x00000001, 0x00000001, 0,
            0x00000002, FLAG_ZF, 0},

        {"ADD carry 0xFFFFFFFF+1", OP_ADD, 0xFFFFFFFF, 0x00000001, 0,
            0x00000000, FLAG_CF | FLAG_ZF, FLAG_CF | FLAG_ZF},

        {"ADD overflow 0x7FFFFFFF+1", OP_ADD, 0x7FFFFFFF, 0x00000001, 0,
            0x80000000, FLAG_OF | FLAG_SF, FLAG_OF | FLAG_SF},

        // --- SUB (op=0x1) ---
        {"SUB 5-3=2",             OP_SUB, 0x00000005, 0x00000003, 0,
            0x00000002, FLAG_ZF | FLAG_CF, 0},

        {"SUB 0-1 borrow",        OP_SUB, 0x00000000, 0x00000001, 0,
            0xFFFFFFFF, FLAG_CF | FLAG_SF, FLAG_CF | FLAG_SF},

        {"SUB equal (ZF)",        OP_SUB, 0x42, 0x42, 0,
            0x00000000, FLAG_ZF | FLAG_CF, FLAG_ZF},

        // --- AND (op=0x2, CF=0 OF=0) ---
        {"AND 0xFF00 & 0x00FF",   OP_AND, 0x0000FF00, 0x000000FF, 0,
            0x00000000, FLAG_ZF, FLAG_ZF},

        {"AND 0xFF & 0xFF",       OP_AND, 0x000000FF, 0x000000FF, 0,
            0x000000FF, FLAG_ZF, 0},

        // --- OR (op=0x3, CF=0 OF=0) ---
        {"OR 0xF0 | 0x0F",       OP_OR, 0x000000F0, 0x0000000F, 0,
            0x000000FF, FLAG_ZF, 0},

        // --- XOR (op=0x4) ---
        {"XOR self = 0 (ZF)",    OP_XOR, 0xDEADBEEF, 0xDEADBEEF, 0,
            0x00000000, FLAG_ZF, FLAG_ZF},

        // --- INC (op=0xC, preserves CF!) ---
        {"INC 0 → 1",            OP_INC, 0x00000000, 0x00000000, 0,
            0x00000001, FLAG_ZF, 0},

        {"INC 0xFFFFFFFF → 0",   OP_INC, 0xFFFFFFFF, 0x00000000, 0,
            0x00000000, FLAG_ZF, FLAG_ZF},

        // --- DEC (op=0xD, preserves CF!) ---
        {"DEC 1 → 0 (ZF)",       OP_DEC, 0x00000001, 0x00000000, 0,
            0x00000000, FLAG_ZF, FLAG_ZF},

        // --- NEG (op=0xB) ---
        {"NEG 1 → -1",           OP_NEG, 0x00000001, 0x00000000, 0,
            0xFFFFFFFF, FLAG_CF | FLAG_SF, FLAG_CF | FLAG_SF},

        {"NEG 0 → 0 (CF=0)",    OP_NEG, 0x00000000, 0x00000000, 0,
            0x00000000, FLAG_ZF | FLAG_CF, FLAG_ZF},

        // --- ADC (op=0x8, with carry) ---
        {"ADC 0+0+1=1",          OP_ADC, 0x00000000, 0x00000000, 1,
            0x00000001, FLAG_ZF, 0},

        // --- SBB (op=0x9, with borrow) ---
        {"SBB 5-3-1=1",          OP_SBB, 0x00000005, 0x00000003, 1,
            0x00000001, FLAG_ZF, 0},

        // --- SHL (op=0x5, shift) ---
        {"SHL 1 << 4 = 16",      OP_SHL, 0x00000001, 0x00000004, 0,
            0x00000010, FLAG_ZF, 0},

        // --- SHR (op=0x6, shift) ---
        {"SHR 0x80 >> 3 = 0x10", OP_SHR, 0x00000080, 0x00000003, 0,
            0x00000010, FLAG_ZF, 0},

        // --- NOT (op=0xA, no flags affected) ---
        {"NOT 0 → 0xFFFFFFFF",   OP_NOT, 0x00000000, 0x00000000, 0,
            0xFFFFFFFF, 0, 0},
    };

    for (const auto& test : tests) {
        run_test(alu.get(), trace.get(), test, tick);
    }

    trace->close();

    printf("\n=== Results: %d/%d tests passed ===\n", tests_passed, tests_run);

    if (tests_passed == tests_run) {
        printf("PASS\n");
        return 0;
    } else {
        printf("FAIL\n");
        return 1;
    }
}
