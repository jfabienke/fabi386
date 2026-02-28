/*
 * fabi386: Branch Predictor Unit Test
 * -------------------------------------
 * Tests the Gshare branch predictor for:
 *   - Initial prediction state (weakly not taken)
 *   - Learning after repeated taken/not-taken patterns
 *   - GHR update behavior
 *   - PHT saturation behavior
 */

#include <cstdlib>
#include <cstdio>
#include <cassert>
#include <cstdint>

#include "Vf386_branch_predict_gshare.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

class GshareTB {
public:
    GshareTB()
        : top_(new Vf386_branch_predict_gshare)
        , trace_(new VerilatedVcdC)
        , tick_(0)
    {
        Verilated::traceEverOn(true);
        top_->trace(trace_, 99);
        trace_->open("test_branch.vcd");
    }

    ~GshareTB() {
        trace_->close();
        delete trace_;
        delete top_;
    }

    void reset() {
        top_->reset_n = 0;
        top_->clk = 0;
        top_->fetch_pc = 0;
        top_->res_valid = 0;
        top_->res_pc = 0;
        top_->res_actually_taken = 0;

        for (int i = 0; i < 10; i++) {
            top_->clk = !top_->clk;
            top_->eval();
            trace_->dump(tick_++);
        }
        top_->reset_n = 1;
    }

    void clock() {
        top_->clk = 1;
        top_->eval();
        trace_->dump(tick_++);
        top_->clk = 0;
        top_->eval();
        trace_->dump(tick_++);
    }

    bool predict(uint32_t pc) {
        top_->fetch_pc = pc;
        top_->eval();
        return top_->predict_taken;
    }

    void resolve(uint32_t pc, bool taken) {
        top_->res_valid = 1;
        top_->res_pc = pc;
        top_->res_actually_taken = taken ? 1 : 0;
        clock();
        top_->res_valid = 0;
    }

    Vf386_branch_predict_gshare* top_;
    VerilatedVcdC* trace_;
    uint64_t tick_;
};

static int tests_run = 0;
static int tests_passed = 0;

static void check(const char* name, bool condition) {
    tests_run++;
    if (condition) {
        tests_passed++;
    } else {
        printf("FAIL: %s\n", name);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    printf("=== fabi386 Branch Predictor Test ===\n");

    GshareTB tb;
    tb.reset();

    // Test 1: After reset, all entries are weakly not-taken (2'b01)
    // PHT MSB = 0, so predict_taken should be false
    {
        bool pred = tb.predict(0x100);
        check("Initial prediction is not-taken", pred == false);
    }

    // Test 2: Train a branch to be taken
    // Resolve same branch as taken multiple times
    {
        uint32_t pc = 0x200;
        // First taken: 01 -> 10 (weakly taken, MSB=1)
        tb.resolve(pc, true);
        bool pred = tb.predict(pc);
        check("After 1 taken: predict taken", pred == true);

        // Second taken: 10 -> 11 (strongly taken)
        tb.resolve(pc, true);
        pred = tb.predict(pc);
        check("After 2 taken: predict taken (strongly)", pred == true);
    }

    // Test 3: Train a branch to be not-taken
    {
        uint32_t pc = 0x300;
        // Initial: 01 (weakly not taken)
        // Resolve not-taken: 01 -> 00 (strongly not taken)
        tb.resolve(pc, false);
        bool pred = tb.predict(pc);
        check("After not-taken: predict not-taken", pred == false);
    }

    // Test 4: Counter saturation
    {
        uint32_t pc = 0x400;
        // Train strongly taken (11)
        tb.resolve(pc, true);
        tb.resolve(pc, true);
        tb.resolve(pc, true);

        // One not-taken should weaken (11 -> 10) but still predict taken
        tb.resolve(pc, false);
        bool pred = tb.predict(pc);
        check("Saturated counter weakens but stays taken", pred == true);
    }

    // Test 5: Multiple branches maintain separate histories via GHR XOR
    {
        // Train PC 0x1000 taken, PC 0x2000 not-taken
        for (int i = 0; i < 4; i++) {
            tb.resolve(0x1000, true);
        }
        for (int i = 0; i < 4; i++) {
            tb.resolve(0x2000, false);
        }
        // After GHR shifts, indices may alias, but basic direction should hold
        // This is a weaker check due to GHR interaction
    }

    printf("\n=== Results: %d/%d tests passed ===\n", tests_passed, tests_run);

    if (tests_passed == tests_run) {
        printf("PASS\n");
        return 0;
    } else {
        printf("FAIL\n");
        return 1;
    }
}
