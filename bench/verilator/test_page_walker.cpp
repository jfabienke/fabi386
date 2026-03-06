/*
 * fabi386: Page Walker Directed Tests (P3.TLB.a Commit 2)
 * ---------------------------------------------------------
 * Tests:
 *   1. PDE not present → fault code P=0
 *   2. PTE not present → fault code P=0
 *   3. User access to supervisor page → fault
 *   4. Write to read-only page → fault
 *   5. A/D update path performs RMW
 *   6. Successful walk returns correct PPN
 *   7. Walk while busy → ignored
 */

#include <cstdio>
#include <cstdlib>
#include <Vpage_walker_tb.h>
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

// Page table entry bits
static constexpr uint32_t PTE_P  = (1 << 0);  // Present
static constexpr uint32_t PTE_RW = (1 << 1);  // Read/Write
static constexpr uint32_t PTE_US = (1 << 2);  // User/Supervisor
static constexpr uint32_t PTE_A  = (1 << 5);  // Accessed
static constexpr uint32_t PTE_D  = (1 << 6);  // Dirty

class PageWalkerTB {
public:
    Vpage_walker_tb *dut;
    uint64_t cycle;

    PageWalkerTB() {
        dut = new Vpage_walker_tb;
        cycle = 0;
        reset();
    }

    ~PageWalkerTB() { delete dut; }

    void tick() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
        cycle++;
    }

    void reset() {
        dut->rst_n = 0;
        dut->tb_walk_req = 0;
        dut->tb_walk_vaddr = 0;
        dut->tb_walk_write = 0;
        dut->tb_walk_user = 0;
        dut->tb_cr3 = 0;
        dut->tb_pt_mem_write = 0;
        dut->tb_pt_mem_write_addr = 0;
        dut->tb_pt_mem_write_data = 0;
        tick();
        tick();
        dut->rst_n = 1;
        tick();
    }

    // Write a 32-bit value to the page table memory model
    void pt_write(uint32_t byte_addr, uint32_t data) {
        dut->tb_pt_mem_write = 1;
        dut->tb_pt_mem_write_addr = byte_addr;
        dut->tb_pt_mem_write_data = data;
        tick();
        dut->tb_pt_mem_write = 0;
    }

    // Start a page walk and wait for completion
    bool walk(uint32_t vaddr, bool write, bool user, int timeout = 100) {
        dut->tb_walk_req = 1;
        dut->tb_walk_vaddr = vaddr;
        dut->tb_walk_write = write ? 1 : 0;
        dut->tb_walk_user = user ? 1 : 0;
        tick();
        dut->tb_walk_req = 0;

        for (int i = 0; i < timeout; i++) {
            if (dut->tb_walk_done) return true;
            tick();
        }
        return false;
    }

    // Setup a simple identity-mapped page table
    // CR3 = 0x0000 (page directory at physical address 0)
    // PDE at index `pdi` → page table at `pt_base`
    // PTE at index `pti` → physical page `ppn`
    void setup_mapping(uint32_t cr3_val, uint32_t vaddr, uint32_t phys_page,
                       uint32_t pde_flags, uint32_t pte_flags) {
        dut->tb_cr3 = cr3_val;

        uint32_t pdi = (vaddr >> 22) & 0x3FF;
        uint32_t pti = (vaddr >> 12) & 0x3FF;

        // Page directory at cr3_val[31:12]
        uint32_t pd_base = cr3_val & 0xFFFFF000;
        // Page table at a separate 4KB region
        uint32_t pt_base = pd_base + 0x1000;

        // PDE: points to page table
        uint32_t pde_addr = pd_base + (pdi * 4);
        uint32_t pde_val  = (pt_base & 0xFFFFF000) | pde_flags;
        pt_write(pde_addr, pde_val);

        // PTE: points to physical page
        uint32_t pte_addr = pt_base + (pti * 4);
        uint32_t pte_val  = (phys_page << 12) | pte_flags;
        pt_write(pte_addr, pte_val);
    }
};

// ================================================================
// Test 1: PDE not present
// ================================================================
void test_pde_not_present(PageWalkerTB &tb) {
    printf("Test 1: PDE not present\n");
    tb.reset();
    tb.dut->tb_cr3 = 0x0000;
    // PDE at offset 0 is zero (not present) by default after reset

    bool done = tb.walk(0x00400000, false, false);
    CHECK(done, "walk completed");
    CHECK(tb.dut->tb_walk_fault == 1, "fault asserted");
    CHECK((tb.dut->tb_walk_fault_code & 0x1) == 0, "fault code P=0 (not present)");
    CHECK(tb.dut->tb_walk_fault_addr == 0x00400000, "fault addr matches vaddr");
}

// ================================================================
// Test 2: PTE not present
// ================================================================
void test_pte_not_present(PageWalkerTB &tb) {
    printf("Test 2: PTE not present\n");
    tb.reset();

    uint32_t cr3 = 0x0000;
    uint32_t vaddr = 0x00401000;
    tb.dut->tb_cr3 = cr3;

    // PDE present, points to page table at 0x1000
    uint32_t pdi = (vaddr >> 22) & 0x3FF;
    tb.pt_write(cr3 + pdi * 4, 0x00001000 | PTE_P | PTE_RW | PTE_US);
    // PTE at index 1 is zero (not present)

    bool done = tb.walk(vaddr, false, false);
    CHECK(done, "walk completed");
    CHECK(tb.dut->tb_walk_fault == 1, "fault asserted");
    CHECK((tb.dut->tb_walk_fault_code & 0x1) == 0, "fault code P=0 (not present)");
}

// ================================================================
// Test 3: User access to supervisor page
// ================================================================
void test_user_supervisor_fault(PageWalkerTB &tb) {
    printf("Test 3: User access to supervisor page\n");
    tb.reset();

    uint32_t cr3 = 0x0000;
    uint32_t vaddr = 0x00000000;
    // PDE: supervisor only (no PTE_US)
    tb.setup_mapping(cr3, vaddr, 0x00100, PTE_P | PTE_RW, PTE_P | PTE_RW | PTE_A);

    bool done = tb.walk(vaddr, false, true);  // user=true
    CHECK(done, "walk completed");
    CHECK(tb.dut->tb_walk_fault == 1, "fault asserted");
    CHECK((tb.dut->tb_walk_fault_code & 0x1) == 1, "fault code P=1 (present but denied)");
    CHECK((tb.dut->tb_walk_fault_code & 0x4) != 0, "fault code U/S=1 (user access)");
}

// ================================================================
// Test 4: Write to read-only page
// ================================================================
void test_write_readonly_fault(PageWalkerTB &tb) {
    printf("Test 4: Write to read-only page\n");
    tb.reset();

    uint32_t cr3 = 0x0000;
    uint32_t vaddr = 0x00000000;
    // PDE: present+RW+US, PTE: present+US but NOT RW
    tb.setup_mapping(cr3, vaddr, 0x00200, PTE_P | PTE_RW | PTE_US, PTE_P | PTE_US | PTE_A);

    bool done = tb.walk(vaddr, true, false);  // write=true
    CHECK(done, "walk completed");
    CHECK(tb.dut->tb_walk_fault == 1, "fault asserted");
    CHECK((tb.dut->tb_walk_fault_code & 0x1) == 1, "fault code P=1");
    CHECK((tb.dut->tb_walk_fault_code & 0x2) != 0, "fault code W/R=1 (write access)");
}

// ================================================================
// Test 5: A/D update path
// ================================================================
void test_ad_update(PageWalkerTB &tb) {
    printf("Test 5: A/D update RMW\n");
    tb.reset();

    uint32_t cr3 = 0x0000;
    uint32_t vaddr = 0x00000000;
    // PTE: present+RW+US but A and D bits NOT set
    tb.setup_mapping(cr3, vaddr, 0x00300, PTE_P | PTE_RW | PTE_US, PTE_P | PTE_RW | PTE_US);

    bool done = tb.walk(vaddr, true, false);  // write=true (should set D bit)
    CHECK(done, "walk completed");
    CHECK(tb.dut->tb_walk_fault == 0, "no fault");
    CHECK(tb.dut->tb_walk_ppn == 0x00300, "correct PPN");
    CHECK(tb.dut->tb_walk_accessed == 1, "accessed bit set");
    CHECK(tb.dut->tb_walk_dirty == 1, "dirty bit set for write");
}

// ================================================================
// Test 6: Successful walk returns correct PPN
// ================================================================
void test_successful_walk(PageWalkerTB &tb) {
    printf("Test 6: Successful walk\n");
    tb.reset();

    uint32_t cr3 = 0x0000;
    uint32_t vaddr = 0x00800000;  // PD index=2, PT index=0
    uint32_t phys_page = 0xABCDE;
    tb.setup_mapping(cr3, vaddr, phys_page,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    bool done = tb.walk(vaddr, false, false);
    CHECK(done, "walk completed");
    CHECK(tb.dut->tb_walk_fault == 0, "no fault");
    CHECK(tb.dut->tb_walk_ppn == (phys_page & 0xFFFFF), "correct PPN");
    CHECK(tb.dut->tb_walk_writable == 1, "writable");
    CHECK(tb.dut->tb_walk_user_out == 1, "user accessible");
}

// ================================================================
// Test 7: Walk while busy is ignored
// ================================================================
void test_walk_while_busy(PageWalkerTB &tb) {
    printf("Test 7: Walk while busy\n");
    tb.reset();

    uint32_t cr3 = 0x0000;
    uint32_t vaddr = 0x00800000;
    tb.setup_mapping(cr3, vaddr, 0x00500,
                     PTE_P | PTE_RW | PTE_US,
                     PTE_P | PTE_RW | PTE_US | PTE_A | PTE_D);

    // Start first walk
    tb.dut->tb_walk_req = 1;
    tb.dut->tb_walk_vaddr = vaddr;
    tb.dut->tb_walk_write = 0;
    tb.dut->tb_walk_user = 0;
    tb.tick();
    tb.dut->tb_walk_req = 0;

    CHECK(tb.dut->tb_busy == 1, "walker is busy");

    // Try to start second walk while first is in progress
    tb.dut->tb_walk_req = 1;
    tb.dut->tb_walk_vaddr = 0xDEAD0000;
    tb.tick();
    tb.dut->tb_walk_req = 0;

    // Wait for first walk to complete
    for (int i = 0; i < 50; i++) {
        if (tb.dut->tb_walk_done) break;
        tb.tick();
    }
    CHECK(tb.dut->tb_walk_done == 1, "first walk completed");
    CHECK(tb.dut->tb_walk_fault == 0, "no fault");
    CHECK(tb.dut->tb_walk_ppn == 0x00500, "correct PPN from first walk (second ignored)");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    PageWalkerTB tb;

    test_pde_not_present(tb);
    test_pte_not_present(tb);
    test_user_supervisor_fault(tb);
    test_write_readonly_fault(tb);
    test_ad_update(tb);
    test_successful_walk(tb);
    test_walk_while_busy(tb);

    printf("\n=== Page Walker Tests: %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
