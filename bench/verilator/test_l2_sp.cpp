/*
 * fabi386: Directed tests for L2 split-phase cache with MSHRs
 *
 * Test 1: Out-of-Order Response Delivery
 * Test 2: Multiple Outstanding Misses Drain
 * Test 3: MMIO (Uncacheable) Ordering Under Load
 * Test 4: MSHR Exhaustion + Stall
 * Test 5: Secondary Miss Stall (same-line conflict)
 * Test 6: Write-Allocate Merge
 * Test 7: Dirty Eviction via MSHR (writeback + fill)
 *
 * Note: Flush coverage is N/A for L2_SP — the module has no flush input.
 * Flush is handled upstream by f386_mem_req_arbiter (force-consumes stale
 * responses). MSHRs always run their DDRAM transactions to completion.
 *
 * TODO: Sub-dword request sizes (1B/2B) — currently all requests use 4B.
 * TODO: Response backpressure (tb_data_rsp_ready=0) — currently always ready.
 * TODO: Ifetch and page-walker port coverage (currently tied off).
 */

#include <cstdio>
#include <cstdint>
#include <vector>
#include <memory>

#include "Vl2_sp_tb.h"
#include "verilated.h"

// Address helpers: L2 geometry is 128KB, 4-way, 32B lines, 1024 sets
// Tag[31:15], Index[14:5], Offset[4:0]
static constexpr uint32_t INDEX_MASK  = 0x3FF;
static constexpr uint32_t INDEX_SHIFT = 5;
static constexpr uint32_t TAG_SHIFT   = 15;

static uint32_t make_addr(uint32_t tag, uint32_t set_idx, uint32_t offset = 0) {
    return (tag << TAG_SHIFT) | ((set_idx & INDEX_MASK) << INDEX_SHIFT) | (offset & 0x1F);
}

struct Response {
    uint8_t  id;
    uint64_t rdata;
    uint64_t cycle;
};

class L2SpTB {
public:
    L2SpTB()
        : top_(new Vl2_sp_tb), cycles_(0), pass_count_(0), fail_count_(0) {
        top_->clk = 0;
        top_->rst_n = 0;
        top_->tb_data_req_valid = 0;
        top_->tb_data_addr = 0;
        top_->tb_data_wdata = 0;
        top_->tb_data_byte_en = 0;
        top_->tb_data_wr = 0;
        top_->tb_data_cacheable = 1;
        top_->tb_data_id = 0;
        top_->tb_data_rsp_ready = 1;
        top_->tb_ddram_latency = 2;
        top_->eval();
    }

    // Tick always records any response that fires
    void tick() {
        top_->clk = 1;
        top_->eval();
        // Sample response on posedge
        if (top_->tb_data_rsp_valid && top_->tb_data_rsp_ready) {
            rsp_log_.push_back({
                static_cast<uint8_t>(top_->tb_data_rsp_id),
                top_->tb_data_rsp_rdata,
                cycles_
            });
        }
        top_->clk = 0;
        top_->eval();
        cycles_++;
    }

    void reset() {
        rsp_log_.clear();
        top_->rst_n = 0;
        for (int i = 0; i < 8; i++) tick();
        top_->rst_n = 1;
        for (int i = 0; i < 4; i++) tick();
        rsp_log_.clear();  // Discard any reset-time responses
    }

    // Clear response log (call before a test scenario)
    void clear_log() { rsp_log_.clear(); }

    // Get collected responses since last clear
    const std::vector<Response>& responses() const { return rsp_log_; }

    // Wait until response log has at least `count` entries
    bool wait_responses(int count, int timeout = 3000) {
        for (int i = 0; i < timeout; i++) {
            if (static_cast<int>(rsp_log_.size()) >= count) return true;
            tick();
        }
        return static_cast<int>(rsp_log_.size()) >= count;
    }

    // Try to issue request, returns true if accepted on this cycle
    bool issue_req(uint32_t addr, uint8_t id, bool is_write = false,
                   uint64_t wdata = 0, uint8_t byte_en = 0xFF,
                   bool cacheable = true) {
        top_->tb_data_addr      = addr;
        top_->tb_data_id        = id;
        top_->tb_data_wr        = is_write ? 1 : 0;
        top_->tb_data_wdata     = wdata;
        top_->tb_data_byte_en   = byte_en;
        top_->tb_data_cacheable = cacheable ? 1 : 0;
        top_->tb_data_req_valid = 1;
        top_->eval();
        bool accepted = top_->tb_data_req_ready != 0;
        tick();
        top_->tb_data_req_valid = 0;
        return accepted;
    }

    // Issue request, retrying until accepted
    bool issue_req_wait(uint32_t addr, uint8_t id, bool is_write = false,
                        uint64_t wdata = 0, uint8_t byte_en = 0xFF,
                        bool cacheable = true, int timeout = 3000) {
        for (int i = 0; i < timeout; i++) {
            top_->tb_data_addr      = addr;
            top_->tb_data_id        = id;
            top_->tb_data_wr        = is_write ? 1 : 0;
            top_->tb_data_wdata     = wdata;
            top_->tb_data_byte_en   = byte_en;
            top_->tb_data_cacheable = cacheable ? 1 : 0;
            top_->tb_data_req_valid = 1;
            top_->eval();
            if (top_->tb_data_req_ready) {
                tick();
                top_->tb_data_req_valid = 0;
                return true;
            }
            tick();
        }
        top_->tb_data_req_valid = 0;
        return false;
    }

    // Prime a cache line (issue load miss, wait for response, drain)
    bool prime_line(uint32_t addr, uint8_t id) {
        size_t before = rsp_log_.size();
        if (!issue_req_wait(addr, id)) return false;
        if (!wait_responses(before + 1)) return false;
        idle(2);
        return true;
    }

    void idle(int n) { for (int i = 0; i < n; i++) tick(); }
    void set_ddram_latency(int lat) { top_->tb_ddram_latency = lat; }
    uint64_t cycle() const { return cycles_; }

    void check(bool cond, const char* msg) {
        if (cond) pass_count_++;
        else { fail_count_++; std::fprintf(stderr, "  FAIL: %s\n", msg); }
    }
    int pass_count() const { return pass_count_; }
    int fail_count() const { return fail_count_; }

private:
    std::unique_ptr<Vl2_sp_tb> top_;
    uint64_t cycles_;
    int pass_count_, fail_count_;
    std::vector<Response> rsp_log_;
};

// =====================================================================
// Test 1: Out-of-Order Response Delivery
// =====================================================================
static void test_ooo_response(L2SpTB& tb) {
    std::printf("Test 1: Out-of-Order Response Delivery\n");
    tb.reset();
    tb.set_ddram_latency(6);  // Slow DDRAM

    // Prime line at set 1 so B and C will hit
    uint32_t addr_hit = make_addr(1, 1, 0);
    tb.check(tb.prime_line(addr_hit, 0x10), "prime hit line");

    tb.clear_log();

    // A: miss to different set
    uint32_t addr_miss = make_addr(2, 2, 0);
    tb.check(tb.issue_req_wait(addr_miss, 0x01), "issue req A (miss)");

    // B: hit to primed line
    tb.check(tb.issue_req_wait(addr_hit, 0x02), "issue req B (hit)");

    // C: hit to primed line (different offset)
    uint32_t addr_hit2 = make_addr(1, 1, 8);
    tb.check(tb.issue_req_wait(addr_hit2, 0x03), "issue req C (hit)");

    // Wait for all 3 responses
    tb.check(tb.wait_responses(3, 5000), "collect 3 responses");

    auto& rsps = tb.responses();
    if (rsps.size() >= 3) {
        // B and C (hits) should arrive before A (miss)
        tb.check(rsps[0].id == 0x02 || rsps[0].id == 0x03,
                 "first response is a hit (B or C)");
        tb.check(rsps[1].id == 0x02 || rsps[1].id == 0x03,
                 "second response is a hit (B or C)");
        tb.check(rsps[2].id == 0x01,
                 "third response is the miss (A)");
        tb.check(rsps[0].id != rsps[1].id,
                 "first two responses are different IDs");
    }
    tb.idle(10);
}

// =====================================================================
// Test 2: Multiple Outstanding Misses Drain
// =====================================================================
static void test_multi_miss_drain(L2SpTB& tb) {
    std::printf("Test 2: Multiple Outstanding Misses Drain\n");
    tb.reset();
    tb.set_ddram_latency(3);

    tb.clear_log();

    uint32_t addr_a = make_addr(5, 10, 0);
    uint32_t addr_b = make_addr(6, 11, 0);
    tb.check(tb.issue_req_wait(addr_a, 0x11), "issue miss A");
    tb.check(tb.issue_req_wait(addr_b, 0x12), "issue miss B");

    tb.check(tb.wait_responses(2, 3000), "collect 2 miss responses");

    auto& rsps = tb.responses();
    bool got_a = false, got_b = false;
    for (auto& r : rsps) {
        if (r.id == 0x11) got_a = true;
        if (r.id == 0x12) got_b = true;
    }
    tb.check(got_a, "got response for miss A");
    tb.check(got_b, "got response for miss B");

    // Post-drain: new request works
    tb.clear_log();
    tb.check(tb.issue_req_wait(make_addr(7, 12, 0), 0x13), "post-drain request");
    tb.check(tb.wait_responses(1, 2000), "post-drain response");
    tb.idle(10);
}

// =====================================================================
// Test 3: MMIO (Uncacheable) Ordering Under Load
// =====================================================================
static void test_mmio_under_load(L2SpTB& tb) {
    std::printf("Test 3: MMIO Ordering Under Load\n");
    tb.reset();
    tb.set_ddram_latency(5);

    tb.clear_log();

    // 3 cacheable misses
    for (int i = 0; i < 3; i++) {
        tb.check(tb.issue_req_wait(make_addr(10+i, 20+i, 0), 0x20+i),
                 "issue cacheable miss");
    }

    // Uncacheable load
    tb.check(tb.issue_req_wait(make_addr(0, 0, 0), 0x30, false, 0, 0xFF, false),
             "issue uncacheable load");

    tb.check(tb.wait_responses(4, 5000), "collect 4 responses");

    bool got_mmio = false;
    for (auto& r : tb.responses())
        if (r.id == 0x30) got_mmio = true;
    tb.check(got_mmio, "got MMIO response");

    tb.idle(10);
}

// =====================================================================
// Test 4: MSHR Exhaustion + Stall
// =====================================================================
static void test_mshr_exhaustion(L2SpTB& tb) {
    std::printf("Test 4: MSHR Exhaustion + Stall\n");
    tb.reset();
    tb.set_ddram_latency(4);

    tb.clear_log();

    // 4 misses to fill all MSHRs
    for (int i = 0; i < 4; i++) {
        tb.check(tb.issue_req_wait(make_addr(30+i, 40+i, 0), 0x40+i),
                 "issue miss to fill MSHR");
    }

    // 5th request should stall then eventually succeed
    tb.check(tb.issue_req_wait(make_addr(34, 44, 0), 0x44, false, 0, 0xFF, true, 5000),
             "5th request accepted after MSHR freed");

    tb.check(tb.wait_responses(5, 5000), "collect all 5 responses");
    tb.idle(10);
}

// =====================================================================
// Test 5: Secondary Miss Stall
// =====================================================================
static void test_secondary_miss_stall(L2SpTB& tb) {
    std::printf("Test 5: Secondary Miss Stall\n");
    tb.reset();
    tb.set_ddram_latency(5);

    tb.clear_log();

    // Miss to tag=50, set=60
    tb.check(tb.issue_req_wait(make_addr(50, 60, 0), 0x28), "issue first miss");

    // Same set+tag, different offset — should stall on MSHR conflict
    tb.check(tb.issue_req_wait(make_addr(50, 60, 8), 0x29, false, 0, 0xFF, true, 5000),
             "second request accepted after MSHR freed");

    tb.check(tb.wait_responses(2, 3000), "collect both responses");

    bool got_28 = false, got_29 = false;
    for (auto& r : tb.responses()) {
        if (r.id == 0x28) got_28 = true;
        if (r.id == 0x29) got_29 = true;
    }
    tb.check(got_28, "got first response");
    tb.check(got_29, "got second response (hit after install)");

    tb.idle(10);
}

// =====================================================================
// Test 6: Write-Allocate Merge
// =====================================================================
static void test_write_allocate(L2SpTB& tb) {
    std::printf("Test 6: Write-Allocate Merge\n");
    tb.reset();
    tb.set_ddram_latency(2);

    tb.clear_log();

    uint32_t addr = make_addr(70, 80, 0);
    uint64_t write_data = 0xCAFEBABE12345678ULL;
    uint8_t  byte_en    = 0x0F;  // Lower 4 bytes

    // Write miss → write-allocate
    tb.check(tb.issue_req_wait(addr, 0x30, true, write_data, byte_en),
             "issue write miss");
    tb.check(tb.wait_responses(1, 3000), "write response received");
    tb.check(tb.responses().back().id == 0x30, "write response has correct ID");

    tb.idle(4);
    tb.clear_log();

    // Read same address — should hit with merged data
    tb.check(tb.issue_req_wait(addr, 0x31), "issue read to same addr");
    tb.check(tb.wait_responses(1, 2000), "read response received");

    if (!tb.responses().empty()) {
        auto& r = tb.responses().back();
        tb.check(r.id == 0x31, "read response has correct ID");
        uint32_t lower = r.rdata & 0xFFFFFFFF;
        tb.check(lower == 0x12345678, "lower 4 bytes match written data");
    }

    tb.idle(10);
}

// =====================================================================
// Test 7: Dirty Eviction via MSHR
// Fill all 4 ways in a set with dirty data (write hits), then miss to
// a 5th tag in the same set → forces dirty eviction + writeback + fill.
// =====================================================================
static void test_dirty_eviction(L2SpTB& tb) {
    std::printf("Test 7: Dirty Eviction via MSHR\n");
    tb.reset();
    tb.set_ddram_latency(2);

    uint32_t set = 100;

    // Prime 4 ways: load miss (fills line), then write hit (dirties it)
    for (int w = 0; w < 4; w++) {
        uint32_t addr = make_addr(w + 1, set, 0);
        tb.clear_log();
        tb.check(tb.prime_line(addr, 0x01 + w), "prime way");
        // Write hit to dirty the line
        tb.clear_log();
        tb.check(tb.issue_req_wait(addr, 0x05 + w, true, 0xDEAD0000ULL | w, 0x0F),
                 "dirty way via write hit");
        tb.check(tb.wait_responses(1, 2000), "write ack");
    }

    tb.idle(10);
    tb.clear_log();

    // 5th tag in same set → miss, evicts one dirty line via MSHR WB
    uint32_t evict_addr = make_addr(5, set, 0);
    tb.check(tb.issue_req_wait(evict_addr, 0x0A), "issue miss forcing dirty eviction");
    tb.check(tb.wait_responses(1, 5000), "eviction miss response received");
    tb.check(tb.responses().back().id == 0x0A, "eviction response has correct ID");

    // Read back the newly installed line — verify it's there
    tb.clear_log();
    tb.check(tb.issue_req_wait(evict_addr, 0x0B), "read back eviction-installed line");
    tb.check(tb.wait_responses(1, 2000), "readback response received");
    tb.check(tb.responses().back().id == 0x0B, "readback response has correct ID");

    // --- Writeback correctness: evict ALL original tags, then refill ---
    // Install 4 fresh tags (5-8) into the same set. Since the set is 4-way,
    // this guarantees all 4 original dirty tags (1-4) are evicted and their
    // data written back to DDRAM. Tag 5 is already installed above; add 6-8.
    for (int t = 6; t <= 8; t++) {
        tb.clear_log();
        uint32_t addr = make_addr(t, set, 0);
        tb.check(tb.issue_req_wait(addr, 0x0A + t), "install replacement tag");
        tb.check(tb.wait_responses(1, 5000), "replacement installed");
    }
    tb.idle(10);

    // Now evict ALL replacement tags (5-8) by installing 4 more fresh tags
    // (9-12). This makes all 4 ways available for refill.
    for (int t = 9; t <= 12; t++) {
        tb.clear_log();
        uint32_t addr = make_addr(t, set, 0);
        tb.check(tb.issue_req_wait(addr, 0x14 + t), "flush replacement tag");
        tb.check(tb.wait_responses(1, 5000), "flush installed");
    }
    tb.idle(10);

    // Read back ALL 4 original tags. Each one MUST miss (no longer in cache),
    // refill from DDRAM, and return the dirty payload we wrote (0xDEAD000w).
    int dirty_verified = 0;
    for (int w = 0; w < 4; w++) {
        uint32_t addr = make_addr(w + 1, set, 0);
        tb.clear_log();
        tb.check(tb.issue_req_wait(addr, 0x20 + w), "read back evicted dirty tag");
        tb.check(tb.wait_responses(1, 5000), "refill response received");

        if (!tb.responses().empty()) {
            uint32_t lower = tb.responses().back().rdata & 0xFFFFFFFF;
            uint32_t expected_dirty = 0xDEAD0000u | w;
            if (lower == expected_dirty) dirty_verified++;
        }
    }
    tb.check(dirty_verified == 4,
             "all 4 dirty payloads survived WB -> DDRAM -> refill roundtrip");

    tb.idle(10);
}

// =====================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    L2SpTB tb;

    auto run_test = [&](const char* name, void (*fn)(L2SpTB&)) {
        int prev_fail = tb.fail_count();
        int prev_pass = tb.pass_count();
        fn(tb);
        int p = tb.pass_count() - prev_pass;
        int f = tb.fail_count() - prev_fail;
        std::printf("  %s: %d passed, %d failed\n\n", f == 0 ? "OK" : "FAILED", p, f);
    };

    run_test("OoO Response",     [](L2SpTB& t) { test_ooo_response(t); });
    run_test("Multi-Miss Drain", [](L2SpTB& t) { test_multi_miss_drain(t); });
    run_test("MMIO Under Load",  [](L2SpTB& t) { test_mmio_under_load(t); });
    run_test("MSHR Exhaustion",  [](L2SpTB& t) { test_mshr_exhaustion(t); });
    run_test("Secondary Miss",   [](L2SpTB& t) { test_secondary_miss_stall(t); });
    run_test("Write-Allocate",   [](L2SpTB& t) { test_write_allocate(t); });
    run_test("Dirty Eviction",   [](L2SpTB& t) { test_dirty_eviction(t); });

    int total_fail = tb.fail_count();
    std::printf("============================================\n");
    std::printf("l2_sp: %d passed, %d failed (%llu total cycles)\n",
                tb.pass_count(), total_fail,
                static_cast<unsigned long long>(tb.cycle()));

    return total_fail > 0 ? 1 : 0;
}
