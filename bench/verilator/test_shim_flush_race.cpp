/*
 * fabi386: Directed test for shim flush/grant/ack race behavior
 */

#include <cstdio>
#include <cstdint>
#include <memory>

#include "Vshim_flush_race_tb.h"
#include "verilated.h"

class ShimRaceTB {
public:
    ShimRaceTB()
        : top_(new Vshim_flush_race_tb)
        , cycles_(0) {
        top_->clk = 0;
        top_->rst_n = 0;
        top_->tb_flush = 0;
        top_->tb_req_valid = 0;
        top_->tb_req_addr = 0;
        top_->tb_req_id = 0;
        top_->tb_req_is_store = 0;
        top_->tb_dn_busy = 0;
        top_->tb_rsp_ready = 1;
        top_->eval();
    }

    void tick() {
        top_->clk = 1;
        top_->eval();
        top_->clk = 0;
        top_->eval();
        cycles_++;
    }

    void reset() {
        top_->rst_n = 0;
        for (int i = 0; i < 4; i++) tick();
        top_->rst_n = 1;
        for (int i = 0; i < 2; i++) tick();
    }

    void pulse_flush() {
        top_->tb_flush = 1;
        tick();
        top_->tb_flush = 0;
        tick();
    }

    void enqueue_load(uint32_t addr, uint8_t id) {
        top_->tb_req_addr = addr;
        top_->tb_req_id = id;
        top_->tb_req_is_store = 0;
        top_->tb_req_valid = 1;

        // One cycle with req_valid high and req_ready sampled.
        tick();
        top_->tb_req_valid = 0;
        tick();
    }

    template <typename Pred>
    bool wait_until(Pred pred, uint64_t timeout_cycles = 2000) {
        for (uint64_t i = 0; i < timeout_cycles; i++) {
            if (pred(top_.get())) return true;
            tick();
        }
        return false;
    }

    Vshim_flush_race_tb* top() { return top_.get(); }
    uint64_t cycles() const { return cycles_; }

private:
    std::unique_ptr<Vshim_flush_race_tb> top_;
    uint64_t cycles_;
};

static bool pred_rsp1(const Vshim_flush_race_tb* t) { return t->tb_rsp_cnt == 1; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    ShimRaceTB tb;
    tb.reset();

    // Baseline: normal completion.
    tb.enqueue_load(0x00001000u, 0x01);
    if (!tb.wait_until(pred_rsp1)) {
        std::fprintf(stderr, "baseline timeout waiting for response\n");
        return 1;
    }
    if (tb.top()->tb_last_rsp_id != 0x01) {
        std::fprintf(stderr, "baseline wrong response id: got %u\n", tb.top()->tb_last_rsp_id);
        return 1;
    }

    // Case 1: flush while request never granted => cancel, no stale issue/response.
    const uint32_t g0_case1 = tb.top()->tb_grant_cnt;
    const uint32_t a0_case1 = tb.top()->tb_ack_cnt;
    const uint32_t r0_case1 = tb.top()->tb_rsp_cnt;
    tb.top()->tb_dn_busy = 1;
    tb.enqueue_load(0x00002000u, 0x02);
    for (int i = 0; i < 4; i++) tb.tick();
    tb.pulse_flush();
    tb.top()->tb_dn_busy = 0;
    for (int i = 0; i < 6; i++) tb.tick();
    if (tb.top()->tb_grant_cnt != g0_case1) {
        std::fprintf(stderr, "case1 stale grant observed after flush\n");
        return 1;
    }
    if (tb.top()->tb_ack_cnt != a0_case1) {
        std::fprintf(stderr, "case1 unexpected ack without grant\n");
        return 1;
    }
    if (tb.top()->tb_rsp_cnt != r0_case1) {
        std::fprintf(stderr, "case1 stale response leaked upstream\n");
        return 1;
    }

    // Case 2: flush after grant before ack => drain, no upstream response.
    const uint32_t g0_case2 = tb.top()->tb_grant_cnt;
    const uint32_t a0_case2 = tb.top()->tb_ack_cnt;
    const uint32_t r0_case2 = tb.top()->tb_rsp_cnt;
    tb.enqueue_load(0x00003000u, 0x03);
    if (!tb.wait_until([&](const Vshim_flush_race_tb* t) { return t->tb_grant_cnt == g0_case2 + 1; })) {
        std::fprintf(stderr, "case2 timeout waiting for grant\n");
        return 1;
    }
    tb.pulse_flush();
    if (!tb.wait_until([&](const Vshim_flush_race_tb* t) { return t->tb_ack_cnt == a0_case2 + 1; })) {
        std::fprintf(stderr, "case2 timeout waiting for ack drain\n");
        return 1;
    }
    for (int i = 0; i < 2; i++) tb.tick();
    if (tb.top()->tb_rsp_cnt != r0_case2) {
        std::fprintf(stderr, "case2 response leaked for flushed request\n");
        return 1;
    }

    // Case 3: flush same cycle as grant => drain, no upstream response.
    const uint32_t g0_case3 = tb.top()->tb_grant_cnt;
    const uint32_t a0_case3 = tb.top()->tb_ack_cnt;
    const uint32_t r0_case3 = tb.top()->tb_rsp_cnt;
    tb.enqueue_load(0x00004000u, 0x04);
    if (!tb.wait_until([](const Vshim_flush_race_tb* t) { return t->tb_data_req && t->tb_data_gnt; })) {
        std::fprintf(stderr, "case3 timeout waiting for req/gnt window\n");
        return 1;
    }
    tb.top()->tb_flush = 1;
    tb.tick();  // posedge with grant+flush together
    tb.top()->tb_flush = 0;
    tb.tick();
    if (tb.top()->tb_grant_cnt != g0_case3 + 1) {
        std::fprintf(stderr, "case3 expected exactly one grant on flush+grant edge\n");
        return 1;
    }
    if (!tb.wait_until([&](const Vshim_flush_race_tb* t) { return t->tb_ack_cnt == a0_case3 + 1; })) {
        std::fprintf(stderr, "case3 timeout waiting for ack drain\n");
        return 1;
    }
    for (int i = 0; i < 2; i++) tb.tick();
    if (tb.top()->tb_rsp_cnt != r0_case3) {
        std::fprintf(stderr, "case3 response leaked for grant+flush race\n");
        return 1;
    }

    // Post-condition: new request still completes.
    const uint32_t r0_post = tb.top()->tb_rsp_cnt;
    tb.enqueue_load(0x00005000u, 0x05);
    if (!tb.wait_until([&](const Vshim_flush_race_tb* t) { return t->tb_rsp_cnt == r0_post + 1; })) {
        std::fprintf(stderr, "post timeout waiting for response\n");
        return 1;
    }
    if (tb.top()->tb_last_rsp_id != 0x05) {
        std::fprintf(stderr, "post wrong response id: got %u\n", tb.top()->tb_last_rsp_id);
        return 1;
    }

    std::printf("shim_flush_race: PASS (%llu cycles)\n",
                static_cast<unsigned long long>(tb.cycles()));
    return 0;
}
