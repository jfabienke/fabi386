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
        , ghr_model_(0)
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
        top_->res_ghr_snap = 0;
        ghr_model_ = 0;

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
        top_->res_ghr_snap = ghr_model_;
        clock();
        top_->res_valid = 0;
        ghr_model_ = static_cast<uint8_t>((ghr_model_ << 1) | (taken ? 1 : 0));
    }

    Vf386_branch_predict_gshare* top_;
    VerilatedVcdC* trace_;
    uint64_t tick_;
    uint8_t ghr_model_;
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

    auto pc_for_target_idx = [&](uint8_t target_idx) -> uint32_t {
        uint8_t pc_idx = static_cast<uint8_t>(target_idx ^ tb.ghr_model_);
        return static_cast<uint32_t>(pc_idx) << 2;
    };

    // Test 1: After reset, all entries are weakly not-taken (2'b01)
    // PHT MSB = 0, so predict_taken should be false
    {
        bool pred = tb.predict(0x100);
        check("Initial prediction is not-taken", pred == false);
    }

    // Test 2: Train one PHT entry to taken using snapshot-correct gshare mapping
    {
        constexpr uint8_t target_idx = 0x42;

        // First taken: 01 -> 10
        tb.resolve(pc_for_target_idx(target_idx), true);
        bool pred = tb.predict(pc_for_target_idx(target_idx));
        check("After 1 taken: predict taken", pred == true);

        // Second taken: 10 -> 11
        tb.resolve(pc_for_target_idx(target_idx), true);
        pred = tb.predict(pc_for_target_idx(target_idx));
        check("After 2 taken: predict taken (strongly)", pred == true);
    }

    // Test 3: Train one PHT entry to not-taken
    {
        constexpr uint8_t target_idx = 0x63;
        tb.resolve(pc_for_target_idx(target_idx), false); // 01 -> 00
        bool pred = tb.predict(pc_for_target_idx(target_idx));
        check("After not-taken: predict not-taken", pred == false);
    }

    // Test 4: Counter saturation
    {
        constexpr uint8_t target_idx = 0x7C;
        // Train strongly taken (11)
        tb.resolve(pc_for_target_idx(target_idx), true);
        tb.resolve(pc_for_target_idx(target_idx), true);
        tb.resolve(pc_for_target_idx(target_idx), true);

        // One not-taken should weaken (11 -> 10) but still predict taken
        tb.resolve(pc_for_target_idx(target_idx), false);
        bool pred = tb.predict(pc_for_target_idx(target_idx));
        check("Saturated counter weakens but stays taken", pred == true);
    }

    // Test 5: Multiple targets maintain separate PHT entries
    {
        constexpr uint8_t idx_taken = 0x15;
        constexpr uint8_t idx_nt    = 0xE2;
        for (int i = 0; i < 4; i++) {
            tb.resolve(pc_for_target_idx(idx_taken), true);
        }
        for (int i = 0; i < 4; i++) {
            tb.resolve(pc_for_target_idx(idx_nt), false);
        }
        check("Taken target remains taken", tb.predict(pc_for_target_idx(idx_taken)) == true);
        check("Not-taken target remains not-taken", tb.predict(pc_for_target_idx(idx_nt)) == false);
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
