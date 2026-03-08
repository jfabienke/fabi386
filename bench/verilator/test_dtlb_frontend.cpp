/*
 * fabi386: DTLB Frontend Directed Tests (P3.TLB.a Commit 3)
 * -----------------------------------------------------------
 * Tests:
 *   1. Paging OFF → single-cycle passthrough
 *   2. Paging ON, TLB hit → correct paddr (after initial walk fills TLB)
 *   3. Paging ON, TLB cold → miss → walk → fill → resp
 *   4. Back-to-back: second request waits until first completes
 *   5. Flush during XL_WALK → clean abort + walker quiesced
 *   6. Flush during XL_WAIT_LOOKUP → clean abort
 *   7. Page fault from walker → resp_fault=1
 *   8. CR3 write flush → next access re-walks
 *   9. CR3 write during walk → clean abort + walker quiesced
 */

#include <cstdio>
#include <cstdlib>
#include <Vdtlb_frontend_tb.h>
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

static constexpr uint32_t PTE_P  = (1 << 0);
static constexpr uint32_t PTE_RW = (1 << 1);
static constexpr uint32_t PTE_US = (1 << 2);
static constexpr uint32_t PTE_A  = (1 << 5);
static constexpr uint32_t PTE_D  = (1 << 6);

class DtlbTB {
public:
    Vdtlb_frontend_tb *dut;
    uint64_t cycle;

    DtlbTB() {
        dut = new Vdtlb_frontend_tb;
        cycle = 0;
        reset();
    }

    ~DtlbTB() { delete dut; }

    void tick() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
        cycle++;
    }

    void reset() {
        dut->rst_n = 0;
        dut->tb_req_valid = 0;
        dut->tb_req_addr = 0;
        dut->tb_req_write = 0;
        dut->tb_req_user = 0;
        dut->tb_paging_enabled = 0;
        dut->tb_flush_all = 0;
        dut->tb_flush = 0;
        dut->tb_invlpg_valid = 0;
        dut->tb_invlpg_vaddr = 0;
        dut->tb_cr3 = 0;
        dut->tb_pt_mem_write = 0;
        dut->tb_pt_mem_write_addr = 0;
        dut->tb_pt_mem_write_data = 0;
        tick();
        tick();
        dut->rst_n = 1;
        tick();
    }

    void pt_write(uint32_t byte_addr, uint32_t data) {
        dut->tb_pt_mem_write = 1;
        dut->tb_pt_mem_write_addr = byte_addr;
        dut->tb_pt_mem_write_data = data;
        tick();
        dut->tb_pt_mem_write = 0;
    }

    // Setup a mapping: vaddr → phys_page
    // Each PD entry gets its own page table at pd_base + 0x1000 + pdi*0x1000
    void setup_mapping(uint32_t cr3_val, uint32_t vaddr, uint32_t phys_page,
                       uint32_t pde_flags, uint32_t pte_flags) {
        dut->tb_cr3 = cr3_val;

        uint32_t pdi = (vaddr >> 22) & 0x3FF;
        uint32_t pti = (vaddr >> 12) & 0x3FF;

        uint32_t pd_base = cr3_val & 0xFFFFF000;
        uint32_t pt_base = pd_base + 0x1000 + pdi * 0x1000;

        pt_write(pd_base + pdi * 4, (pt_base & 0xFFFFF000) | pde_flags);
        pt_write(pt_base + pti * 4, (phys_page << 12) | pte_flags);
    }

    // Issue a request and wait for response
    bool request(uint32_t addr, bool write, bool user, int timeout = 200) {
        dut->tb_req_valid = 1;
        dut->tb_req_addr = addr;
        dut->tb_req_write = write ? 1 : 0;
        dut->tb_req_user = user ? 1 : 0;
        tick();
        dut->tb_req_valid = 0;

        for (int i = 0; i < timeout; i++) {
            if (dut->tb_resp_valid) return true;
            tick();
        }
        return false;
    }

    // Wait for response without issuing new request
    bool wait_resp(int timeout = 200) {
        for (int i = 0; i < timeout; i++) {
            if (dut->tb_resp_valid) return true;
            tick();
        }
        return false;
    }
};

// ================================================================
// Test 1: Paging OFF → passthrough
// ================================================================
void test_paging_off_passthrough(DtlbTB &tb) {
    printf("Test 1: Paging OFF passthrough\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 0;

    uint32_t addr = 0x12345678;
    bool done = tb.request(addr, false, false);
    CHECK(done, "response received");
    CHECK(tb.dut->tb_resp_fault == 0, "no fault");
    CHECK(tb.dut->tb_resp_paddr == addr, "paddr == linear addr (passthrough)");
}

// ================================================================
// Test 2: Paging ON, TLB hit after initial walk
// ================================================================
void test_tlb_hit_after_walk(DtlbTB &tb) {
    printf("Test 2: TLB hit after initial walk\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 1;

    uint32_t vaddr = 0x00000ABC;  // page 0x00000, offset 0xABC
    uint32_t phys_page = 0x00500;
    tb.setup_mapping(0x0000, vaddr, phys_page,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    // First access: TLB miss → walk
    bool done = tb.request(vaddr, false, false);
    CHECK(done, "first access completed");
    CHECK(tb.dut->tb_resp_fault == 0, "no fault");
    CHECK(tb.dut->tb_resp_paddr == ((phys_page << 12) | 0xABC),
          "correct translated address");

    // Settle
    tb.tick();
    tb.tick();

    // Second access: TLB hit (faster)
    uint64_t start_cycle = tb.cycle;
    done = tb.request(vaddr, false, false);
    CHECK(done, "second access completed");
    uint64_t hit_latency = tb.cycle - start_cycle;
    CHECK(hit_latency <= 5, "TLB hit latency <= 5 cycles");
    CHECK(tb.dut->tb_resp_paddr == ((phys_page << 12) | 0xABC),
          "same translated address on hit");
}

// ================================================================
// Test 3: TLB cold miss → walk → fill → response
// ================================================================
void test_cold_miss_walk(DtlbTB &tb) {
    printf("Test 3: TLB cold miss\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 1;

    uint32_t vaddr = 0x00400000;  // PD index=1, PT index=0
    uint32_t phys_page = 0xABCDE;
    tb.setup_mapping(0x0000, vaddr, phys_page,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    uint64_t start = tb.cycle;
    bool done = tb.request(vaddr, false, false);
    CHECK(done, "walk completed");
    CHECK(tb.dut->tb_resp_fault == 0, "no fault");
    CHECK(tb.dut->tb_resp_paddr == ((phys_page << 12) | 0),
          "correct PPN with offset 0");
    uint64_t miss_lat = tb.cycle - start;
    CHECK(miss_lat >= 5, "miss latency >= 5 cycles (walk takes time)");
}

// ================================================================
// Test 4: Back-to-back requests (busy gating)
// ================================================================
void test_back_to_back(DtlbTB &tb) {
    printf("Test 4: Back-to-back requests\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 1;

    // Setup two different mappings
    uint32_t vaddr1 = 0x00000000;
    uint32_t vaddr2 = 0x00400000;
    tb.setup_mapping(0x0000, vaddr1, 0x100,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);
    tb.setup_mapping(0x0000, vaddr2, 0x200,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    // First request
    bool done = tb.request(vaddr1, false, false);
    CHECK(done, "first request completed");
    CHECK(tb.dut->tb_resp_paddr == (0x100 << 12), "first paddr correct");

    tb.tick();

    // Second request (should also complete)
    done = tb.request(vaddr2, false, false);
    CHECK(done, "second request completed");
    CHECK(tb.dut->tb_resp_paddr == (0x200 << 12), "second paddr correct");
}

// ================================================================
// Test 5: Flush during walk
// ================================================================
void test_flush_during_walk(DtlbTB &tb) {
    printf("Test 5: Flush during walk\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 1;

    uint32_t vaddr = 0x00000000;
    tb.setup_mapping(0x0000, vaddr, 0x300,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    // Start request
    tb.dut->tb_req_valid = 1;
    tb.dut->tb_req_addr = vaddr;
    tb.dut->tb_req_write = 0;
    tb.dut->tb_req_user = 0;
    tb.tick();
    tb.dut->tb_req_valid = 0;

    // Wait a couple cycles for TLB miss → enter walk
    tb.tick();
    tb.tick();
    tb.tick();

    // Flush
    tb.dut->tb_flush = 1;
    tb.tick();
    tb.dut->tb_flush = 0;
    tb.tick();

    CHECK(tb.dut->tb_busy == 0, "frontend returned to idle after flush");
    CHECK(tb.dut->tb_pt_req == 0, "walker pt_req quiesced after flush");

    // Verify no stale response appears
    bool got_resp = false;
    for (int i = 0; i < 30; i++) {
        if (tb.dut->tb_resp_valid) {
            got_resp = true;
            break;
        }
        tb.tick();
    }
    CHECK(!got_resp, "no stale response after flush");
}

// ================================================================
// Test 6: Flush during WAIT_LOOKUP
// ================================================================
void test_flush_during_lookup(DtlbTB &tb) {
    printf("Test 6: Flush during lookup\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 1;

    // Don't set up any mapping — TLB will miss but we flush before walk

    tb.dut->tb_req_valid = 1;
    tb.dut->tb_req_addr = 0x1000;
    tb.dut->tb_req_write = 0;
    tb.dut->tb_req_user = 0;
    tb.tick();
    tb.dut->tb_req_valid = 0;

    // One cycle into lookup
    tb.tick();

    // Flush
    tb.dut->tb_flush = 1;
    tb.tick();
    tb.dut->tb_flush = 0;
    tb.tick();

    CHECK(tb.dut->tb_busy == 0, "frontend returned to idle after lookup flush");
}

// ================================================================
// Test 7: Page fault from walker
// ================================================================
void test_page_fault(DtlbTB &tb) {
    printf("Test 7: Page fault\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 1;
    tb.dut->tb_cr3 = 0x0000;

    // PDE not present → fault
    bool done = tb.request(0x00500000, false, false);
    CHECK(done, "fault response received");
    CHECK(tb.dut->tb_resp_fault == 1, "fault asserted");
    CHECK(tb.dut->tb_resp_fault_addr == 0x00500000, "fault addr correct");
}

// ================================================================
// Test 8: CR3 write flush → re-walk
// ================================================================
void test_cr3_flush(DtlbTB &tb) {
    printf("Test 8: CR3 write flush\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 1;

    uint32_t vaddr = 0x00000000;
    uint32_t phys_page1 = 0x100;
    tb.setup_mapping(0x0000, vaddr, phys_page1,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    // First access: fills TLB
    bool done = tb.request(vaddr, false, false);
    CHECK(done, "first access completed");
    CHECK(tb.dut->tb_resp_paddr == (phys_page1 << 12), "first mapping correct");

    tb.tick();

    // CR3 write flush
    tb.dut->tb_flush_all = 1;
    tb.tick();
    tb.dut->tb_flush_all = 0;
    tb.tick();

    // Change mapping to different physical page
    uint32_t phys_page2 = 0x200;
    tb.setup_mapping(0x0000, vaddr, phys_page2,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    // Second access: should re-walk (TLB was flushed)
    done = tb.request(vaddr, false, false);
    CHECK(done, "second access completed after CR3 flush");
    CHECK(tb.dut->tb_resp_paddr == (phys_page2 << 12),
          "new mapping used after CR3 flush");
}

// ================================================================
// Test 9: CR3 write during walk → clean abort + walker quiesced
// ================================================================
void test_cr3_flush_during_walk(DtlbTB &tb) {
    printf("Test 9: CR3 write during walk\n");
    tb.reset();
    tb.dut->tb_paging_enabled = 1;

    uint32_t vaddr = 0x00000000;
    tb.setup_mapping(0x0000, vaddr, 0x300,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    // Start request
    tb.dut->tb_req_valid = 1;
    tb.dut->tb_req_addr = vaddr;
    tb.dut->tb_req_write = 0;
    tb.dut->tb_req_user = 0;
    tb.tick();
    tb.dut->tb_req_valid = 0;

    // Wait for TLB miss → enter walk
    tb.tick();
    tb.tick();
    tb.tick();

    // CR3 write (flush_all) during walk
    tb.dut->tb_flush_all = 1;
    tb.tick();
    tb.dut->tb_flush_all = 0;
    tb.tick();

    CHECK(tb.dut->tb_busy == 0, "frontend returned to idle after CR3 flush during walk");
    CHECK(tb.dut->tb_pt_req == 0, "walker pt_req quiesced after CR3 flush");

    // Verify no stale response
    bool got_resp = false;
    for (int i = 0; i < 30; i++) {
        if (tb.dut->tb_resp_valid) {
            got_resp = true;
            break;
        }
        tb.tick();
    }
    CHECK(!got_resp, "no stale response after CR3 flush during walk");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    DtlbTB tb;

    test_paging_off_passthrough(tb);
    test_tlb_hit_after_walk(tb);
    test_cold_miss_walk(tb);
    test_back_to_back(tb);
    test_flush_during_walk(tb);
    test_flush_during_lookup(tb);
    test_page_fault(tb);
    test_cr3_flush(tb);
    test_cr3_flush_during_walk(tb);

    printf("\n=== DTLB Frontend Tests: %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
