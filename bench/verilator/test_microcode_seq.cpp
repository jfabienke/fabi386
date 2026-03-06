/*
 * Microcode Sequencer Directed Tests (P3.1a)
 * -------------------------------------------
 * Standalone testbench exercising f386_microcode_sequencer directly.
 * Does NOT require core_top or feature gate override.
 *
 * Tests:
 *   1. NOP (0x90) — 1-step sequence
 *   2. CPUID (0F A2) — 4-step atomic sequence
 *   3. PUSHA (0x60) — 8-step atomic sequence
 *   4. Flush during sequence — immediate return to IDLE
 *   5. Group remap (F7 /4 MUL) — verify virtual opcode remap
 */

#include <cstdio>
#include <cstdlib>
#include <Vmicrocode_seq_tb.h>
#include <verilated.h>

static int g_pass = 0, g_fail = 0;

#define CHECK(cond, msg)                                              \
    do {                                                              \
        if (cond) { g_pass++; }                                       \
        else {                                                        \
            printf("  FAIL: %s (line %d)\n", msg, __LINE__);          \
            g_fail++;                                                 \
        }                                                             \
    } while (0)

class SeqTB {
public:
    Vmicrocode_seq_tb *dut;
    uint64_t cycle;

    SeqTB() {
        dut = new Vmicrocode_seq_tb;
        cycle = 0;
        reset();
    }

    ~SeqTB() { delete dut; }

    void tick() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
        cycle++;
    }

    void reset() {
        dut->rst_n = 0;
        dut->flush = 0;
        dut->start = 0;
        dut->exec_ack = 0;
        dut->opcode = 0;
        dut->opcode_ext = 0;
        dut->is_0f_prefix = 0;
        dut->is_rep_prefix = 0;
        dut->is_repne = 0;
        dut->is_32bit = 0;
        dut->modrm_reg = 0;
        dut->instr_pc = 0;
        dut->rep_ecx_zero = 1;
        dut->rep_zf_value = 0;
        tick();
        tick();
        dut->rst_n = 1;
        tick();
    }

    // Trigger sequencer with given opcode
    void trigger(uint8_t opc, bool is_0f = false, uint8_t ext = 0,
                 uint8_t modrm = 0, bool rep = false, bool repne = false) {
        dut->start = 1;
        dut->opcode = opc;
        dut->opcode_ext = ext;
        dut->is_0f_prefix = is_0f ? 1 : 0;
        dut->is_rep_prefix = rep ? 1 : 0;
        dut->is_repne = repne ? 1 : 0;
        dut->is_32bit = 1;
        dut->modrm_reg = modrm;
        dut->instr_pc = 0x1000;
        tick();
        dut->start = 0;
    }

    // Wait for uop_valid, return cycle count. Max 100 cycles.
    int wait_uop_valid(int max_cycles = 100) {
        for (int i = 0; i < max_cycles; i++) {
            if (dut->uop_valid) return i;
            tick();
        }
        return -1;
    }

    // Acknowledge current micro-op and wait for sequencer to settle
    // Sequencer: SEQ_STALL --(ack)--> SEQ_ACTIVE --(1cyc)--> SEQ_STALL
    void ack_and_advance() {
        dut->exec_ack = 1;
        tick();              // SEQ_STALL sees ack → SEQ_ACTIVE
        dut->exec_ack = 0;
        tick();              // SEQ_ACTIVE → SEQ_STALL (new step ready)
    }

    // Run full sequence: trigger, then ack each micro-op. Returns step count.
    int run_full_sequence(uint8_t opc, bool is_0f = false, uint8_t ext = 0,
                          uint8_t modrm = 0) {
        trigger(opc, is_0f, ext, modrm);
        int steps = 0;
        int timeout = 200;
        while (timeout-- > 0) {
            int w = wait_uop_valid(50);
            if (w < 0) break;  // No more micro-ops
            steps++;
            bool is_last = dut->uop_is_last;
            ack_and_advance();
            if (is_last) break;
        }
        return steps;
    }
};

// ============================================================
// Test 1: NOP (0x90)
// ============================================================
void test_nop(SeqTB &tb) {
    printf("Test 1: NOP (0x90)\n");
    tb.reset();

    tb.trigger(0x90);
    int w = tb.wait_uop_valid();
    CHECK(w >= 0, "uop_valid asserted after trigger");
    CHECK(tb.dut->uop_is_last == 1, "NOP is single-step (uop_is_last=1)");
    CHECK(tb.dut->busy == 1, "Sequencer busy during sequence");

    tb.ack_and_advance();
    tb.tick();  // Let FSM settle
    CHECK(tb.dut->busy == 0, "Sequencer idle after NOP completes");
}

// ============================================================
// Test 2: INT (0xCD) — 5-step atomic
// ============================================================
void test_int(SeqTB &tb) {
    printf("Test 2: INT (0xCD)\n");
    tb.reset();

    // Trigger and verify atomicity on first step
    tb.trigger(0xCD);
    int w = tb.wait_uop_valid();
    CHECK(w >= 0, "First uop_valid");
    CHECK(tb.dut->uop_is_atomic == 1, "INT is atomic");
    CHECK(tb.dut->block_interrupt == 1, "Interrupts blocked during INT");

    // Complete remaining steps
    int steps = 1;
    while (steps < 20) {
        bool is_last = tb.dut->uop_is_last;
        tb.ack_and_advance();
        if (is_last) break;
        int w2 = tb.wait_uop_valid();
        if (w2 < 0) break;
        steps++;
    }
    CHECK(steps == 5, "INT is 5 steps");

    tb.tick();
    CHECK(tb.dut->busy == 0, "Sequencer idle after INT");
}

// ============================================================
// Test 3: PUSHA (0x60) — 8-step atomic
// ============================================================
void test_pusha(SeqTB &tb) {
    printf("Test 3: PUSHA (0x60)\n");
    tb.reset();

    // Trigger and verify atomicity
    tb.trigger(0x60);
    int w = tb.wait_uop_valid();
    CHECK(w >= 0, "First uop_valid");
    CHECK(tb.dut->uop_is_atomic == 1, "PUSHA is atomic");
    CHECK(tb.dut->block_interrupt == 1, "Interrupts blocked during PUSHA");

    // Run remaining steps
    int steps = 1;
    while (steps < 20) {
        bool is_last = tb.dut->uop_is_last;
        tb.ack_and_advance();
        if (is_last) break;
        int w2 = tb.wait_uop_valid();
        if (w2 < 0) break;
        steps++;
    }
    CHECK(steps == 8, "PUSHA is 8 steps");

    tb.tick();
    CHECK(tb.dut->busy == 0, "Sequencer idle after PUSHA");
    CHECK(tb.dut->block_interrupt == 0, "Interrupts unblocked after PUSHA");
}

// ============================================================
// Test 4: Flush during sequence
// ============================================================
void test_flush_mid_sequence(SeqTB &tb) {
    printf("Test 4: Flush during sequence\n");
    tb.reset();

    // Start PUSHA (8 steps), ack first 2, then flush
    tb.trigger(0x60);
    tb.wait_uop_valid();
    tb.ack_and_advance();
    tb.wait_uop_valid();
    tb.ack_and_advance();
    tb.wait_uop_valid();  // Step 3 presented

    CHECK(tb.dut->busy == 1, "Busy before flush");

    // Assert flush
    tb.dut->flush = 1;
    tb.tick();
    tb.dut->flush = 0;
    tb.tick();

    CHECK(tb.dut->busy == 0, "Sequencer idle after flush");
    CHECK(tb.dut->uop_valid == 0, "uop_valid cleared after flush");
}

// ============================================================
// Test 5: Group remap — F7 /4 (MUL dword)
// ============================================================
void test_group_remap(SeqTB &tb) {
    printf("Test 5: Group remap (F7 /4 = MUL)\n");
    tb.reset();

    // F7 /4 is MUL dword, modrm_reg=4
    int steps = tb.run_full_sequence(0xF7, false, 0, 4);
    CHECK(steps > 0, "MUL group remap produces micro-ops");

    tb.tick();
    CHECK(tb.dut->busy == 0, "Sequencer idle after MUL");
}

// ============================================================
// Main
// ============================================================
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    SeqTB tb;

    printf("=== Microcode Sequencer Tests ===\n\n");

    test_nop(tb);
    test_int(tb);
    test_pusha(tb);
    test_flush_mid_sequence(tb);
    test_group_remap(tb);

    printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail > 0 ? 1 : 0;
}
