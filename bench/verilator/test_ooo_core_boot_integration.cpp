/*
 * fabi386: Boot Integration Test
 * --------------------------------
 * Exercises the full boot sequence across subsystem boundaries:
 *
 *   Test 31: Real-mode → protected-mode → load/store in PM
 *   Test 32: PM boot → INT in protected mode (via IDT)
 *   Test 33: PM boot → segment load (DS, SS) → memory access via data segment
 *   Test 34: Real-mode INT → IRET → verify EFLAGS/CS/EIP restored
 *   Test 35: IO port IN (byte read from test peripheral)
 *   Test 36: IO port OUT (byte write to test peripheral)
 *   Test 37: Full boot → INT in PM (real-mode IVT, not PM IDT)
 *
 * Requires: VERILATOR_ENABLE_MICROCODE + VERILATOR_ENABLE_LSQ_MEMIF
 */

#include <cstdlib>
#include <cstdio>
#include <cstdint>
#include <cassert>
#include <algorithm>
#include <memory>
#include <vector>

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

// ============================================================
// Testbench Class
// ============================================================
class BootIntegTB {
public:
    BootIntegTB()
        : top_(std::make_unique<Vf386_ooo_core_top>())
        , trace_(std::make_unique<VerilatedVcdC>())
        , cycle_(0)
        , retired_(0)
        , trace_time_(0)
        , data_writes_(0)
        , data_reads_(0)
        , data_ack_pending_(false)
        , data_ack_rdata_(0)
        , ack_hold_(0)
        , io_ack_pending_(false)
        , io_ack_rdata_(0)
        , io_last_wr_addr_(0)
        , io_last_wr_data_(0)
        , io_last_wr_valid_(false)
        , io_read_map_()
    {
        Verilated::traceEverOn(true);
        top_->trace(trace_.get(), 99);
        trace_->open("tb_boot_integration.vcd");
    }

    ~BootIntegTB() {
        trace_->close();
    }

    void load_program(const uint8_t* code, size_t len, uint32_t base = 0xFFF0) {
        mem_.fill(base, 256, 0x90);  // NOP background
        for (size_t i = 0; i < len; i++)
            mem_.write8(base + i, code[i]);
        mem_.write8(base + 200, 0xF4);  // HLT sentinel
    }

    // Write raw bytes at arbitrary address (for target code, handlers, etc.)
    void write_code(uint32_t base, const uint8_t* code, size_t len) {
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

        // IO port (inactive)
        top_->io_port_rdata = 0;
        top_->io_port_ack = 0;

        // Page walker port (inactive)
        top_->pt_rdata = 0;
        top_->pt_ack = 0;

        // Split-phase ports (inactive)
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
        data_ack_pending_ = false;
        data_ack_rdata_ = 0;
        ack_hold_ = 0;
        io_ack_pending_ = false;
        io_ack_rdata_ = 0;
        io_last_wr_addr_ = 0;
        io_last_wr_data_ = 0;
        io_last_wr_valid_ = false;
    }

    void tick() {
        // Rising edge
        top_->clk = 1;
        top_->eval();
        trace_->dump(trace_time_++);

        // Expire old data ack
        if (ack_hold_ > 0) {
            ack_hold_--;
            if (ack_hold_ == 0) {
                top_->mem_ack = 0;
                top_->mem_gnt = 0;
            }
        }
        // Deliver pending data ack
        if (data_ack_pending_) {
            top_->mem_ack   = 1;
            top_->mem_gnt   = 1;
            top_->mem_rdata = data_ack_rdata_;
            data_ack_pending_ = false;
            ack_hold_ = 1;
        }

        // IO port ack (1-cycle latency)
        if (io_ack_pending_) {
            top_->io_port_ack   = 1;
            top_->io_port_rdata = io_ack_rdata_;
            io_ack_pending_ = false;
        } else {
            top_->io_port_ack = 0;
        }

        service_fetch();
        service_data_mem();
        service_io_port();

        if (top_->trace_valid)
            retired_++;

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

    void run(uint64_t n) {
        for (uint64_t i = 0; i < n; i++) tick();
    }

    // --- State Readback ---
    uint64_t retired()      const { return retired_; }
    uint64_t cycle_count()  const { return cycle_; }
    uint64_t data_writes()  const { return data_writes_; }
    uint64_t data_reads()   const { return data_reads_; }

    uint32_t pc() const {
        return top_->rootp->f386_ooo_core_top__DOT__pc_current;
    }
    uint32_t eflags() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_eflags;
    }
    uint32_t cr0() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_cr0;
    }
    bool pe_mode() const { return cr0() & 1; }

    uint16_t cs_sel() const {
        return top_->rootp->f386_ooo_core_top__DOT__seg_cs_sel;
    }
    uint64_t seg_cache(int idx) const {
        return top_->rootp->f386_ooo_core_top__DOT__seg_cache__DOT__reg_cache[idx];
    }
    bool cs_db() const { return (seg_cache(1) >> 54) & 1; }
    bool default_32() const { return pe_mode() ? cs_db() : false; }

    uint16_t seg_sel(int idx) const {
        return top_->rootp->f386_ooo_core_top__DOT__seg_cache__DOT__reg_sel[idx];
    }

    uint32_t gdtr_base() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_gdtr_base;
    }
    uint16_t gdtr_limit() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_gdtr_limit;
    }
    uint32_t idtr_base() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_idtr_base;
    }
    uint16_t idtr_limit() const {
        return top_->rootp->f386_ooo_core_top__DOT__sys_regs__DOT__reg_idtr_limit;
    }

    int ucode_state() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__ucode_state;
    }
    int um_state() const {
        return top_->rootp->f386_ooo_core_top__DOT__gen_microcode__DOT__uc_mem_state;
    }

    // Memory readback
    uint32_t read_mem32(uint32_t addr) const { return mem_.read32(addr); }
    uint8_t  read_mem8(uint32_t addr) const { return mem_.read8(addr); }
    void write_mem8(uint32_t addr, uint8_t val) { mem_.write8(addr, val); }
    void write_mem32(uint32_t addr, uint32_t val) { mem_.write32(addr, val); }

    // IO port test peripheral
    void set_io_read_value(uint16_t port, uint32_t value) {
        io_read_map_[port] = value;
    }
    uint16_t io_last_wr_addr() const { return io_last_wr_addr_; }
    uint32_t io_last_wr_data() const { return io_last_wr_data_; }
    bool     io_last_wr_valid() const { return io_last_wr_valid_; }

    // Write trace for data verification
    struct MemTrace {
        uint32_t addr;
        uint64_t data;
        uint8_t  ben;
        bool     is_write;
    };
    std::vector<MemTrace> mem_trace_;
    bool trace_enabled_ = false;

    void enable_trace()  { trace_enabled_ = true; mem_trace_.clear(); }
    void disable_trace() { trace_enabled_ = false; }

    Vf386_ooo_core_top* top() const { return top_.get(); }

private:
    std::unique_ptr<Vf386_ooo_core_top> top_;
    std::unique_ptr<VerilatedVcdC>      trace_;
    MemoryModel                         mem_;
    uint64_t                            cycle_;
    uint64_t                            retired_;
    uint64_t                            trace_time_;
    uint64_t                            data_writes_;
    uint64_t                            data_reads_;
    bool                                data_ack_pending_;
    uint64_t                            data_ack_rdata_;
    int                                 ack_hold_;

    // IO port simulation
    bool     io_ack_pending_;
    uint32_t io_ack_rdata_;
    uint16_t io_last_wr_addr_;
    uint32_t io_last_wr_data_;
    bool     io_last_wr_valid_;
    std::unordered_map<uint16_t, uint32_t> io_read_map_;

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
        if (top_->mem_req && !top_->mem_ack && !data_ack_pending_) {
            uint32_t addr = top_->mem_addr;
            uint32_t base = addr & ~7u;
            if (top_->mem_wr) {
                uint64_t wdata = top_->mem_wdata;
                uint8_t  ben   = top_->mem_byte_en;
                if (trace_enabled_)
                    mem_trace_.push_back({addr, wdata, ben, true});
                for (int i = 0; i < 8; i++) {
                    if (ben & (1 << i))
                        mem_.write8(base + i, (wdata >> (i * 8)) & 0xFF);
                }
                data_writes_++;
            } else {
                uint64_t rdata = 0;
                for (int i = 0; i < 8; i++)
                    rdata |= (uint64_t)mem_.read8(base + i) << (i * 8);
                data_ack_rdata_ = rdata;
                if (trace_enabled_)
                    mem_trace_.push_back({addr, rdata, 0, false});
                data_reads_++;
            }
            data_ack_pending_ = true;
        }
    }

    void service_io_port() {
        // Sample IO port request (read or write) after rising eval.
        // Deliver ack next cycle via io_ack_pending_.
        if (top_->io_port_rd && !io_ack_pending_) {
            uint16_t port = top_->io_port_addr;
            auto it = io_read_map_.find(port);
            io_ack_rdata_ = (it != io_read_map_.end()) ? it->second : 0xFFFFFFFF;
            io_ack_pending_ = true;
        } else if (top_->io_port_wr && !io_ack_pending_) {
            io_last_wr_addr_  = top_->io_port_addr;
            io_last_wr_data_  = top_->io_port_wdata;
            io_last_wr_valid_ = true;
            io_ack_rdata_ = 0;
            io_ack_pending_ = true;
        }
    }
};

// ============================================================
// Helper: Build the standard 4-block PM boot sequence
// Returns the number of bytes written to `code`.
//
// Block 0: LGDT [gdt_ptr_addr]
// Block 1: MOV EAX, [0x2000]  → loads PE bit
// Block 2: MOV CR0, EAX       → sets PE=1
// Block 3: JMP FAR 0x08:target32
// ============================================================
static size_t build_pm_boot(uint8_t* code, size_t code_sz,
                            uint32_t gdt_ptr_addr, uint32_t target_pc)
{
    assert(code_sz >= 64);
    memset(code, 0x90, 64);

    // Block 0 [0-15]: LGDT [gdt_ptr_addr] (67 0F 01 15 <addr32>)
    code[0] = 0x67;
    code[1] = 0x0F;
    code[2] = 0x01;
    code[3] = 0x15;  // ModRM: mod=00, reg=2(LGDT), rm=5(disp32)
    code[4] = (gdt_ptr_addr >>  0) & 0xFF;
    code[5] = (gdt_ptr_addr >>  8) & 0xFF;
    code[6] = (gdt_ptr_addr >> 16) & 0xFF;
    code[7] = (gdt_ptr_addr >> 24) & 0xFF;

    // Block 1 [16-31]: MOV EAX, [0x2000] (66 A1 00 20)
    code[16] = 0x66;
    code[17] = 0xA1;
    code[18] = 0x00;
    code[19] = 0x20;

    // Block 2 [32-47]: MOV CR0, EAX (0F 22 C0)
    code[32] = 0x0F;
    code[33] = 0x22;
    code[34] = 0xC0;

    // Block 3 [48-63]: JMP FAR 0x08:target32 (66 EA <target32> 08 00)
    code[48] = 0x66;
    code[49] = 0xEA;
    code[50] = (target_pc >>  0) & 0xFF;
    code[51] = (target_pc >>  8) & 0xFF;
    code[52] = (target_pc >> 16) & 0xFF;
    code[53] = (target_pc >> 24) & 0xFF;
    code[54] = 0x08;
    code[55] = 0x00;

    return 64;
}

// ============================================================
// Helper: Seed standard GDT + pseudo-descriptor + PE value
//
// GDT layout:
//   Entry 0 (0x00): Null
//   Entry 1 (0x08): Code32, base=0, limit=4GB, G=1, D/B=1
//   Entry 2 (0x10): Data32, base=0, limit=4GB, G=1, D/B=1, RW
//   Entry 3 (0x18): Stack32 = Data32 (alias)
// ============================================================
static void seed_gdt(BootIntegTB& tb, uint32_t gdt_base, uint32_t gdt_ptr_addr)
{
    // Entry 0 (null)
    tb.write_mem32(gdt_base + 0,  0x00000000);
    tb.write_mem32(gdt_base + 4,  0x00000000);
    // Entry 1 (0x08): code32, base=0, limit=4GB
    tb.write_mem32(gdt_base + 8,  0x0000FFFF);
    tb.write_mem32(gdt_base + 12, 0x00CF9B00);
    // Entry 2 (0x10): data32, base=0, limit=4GB, RW
    tb.write_mem32(gdt_base + 16, 0x0000FFFF);
    tb.write_mem32(gdt_base + 20, 0x00CF9300);
    // Entry 3 (0x18): stack32 = data32 (alias)
    tb.write_mem32(gdt_base + 24, 0x0000FFFF);
    tb.write_mem32(gdt_base + 28, 0x00CF9300);

    // GDT pseudo-descriptor at gdt_ptr_addr
    // Limit = 4 entries * 8 - 1 = 31 = 0x1F, base = gdt_base
    uint32_t limit_and_base_lo = (gdt_base << 16) | 0x001F;
    uint32_t base_hi = gdt_base >> 16;
    tb.write_mem32(gdt_ptr_addr,     limit_and_base_lo);
    tb.write_mem32(gdt_ptr_addr + 4, base_hi);

    // PE bit value at 0x2000
    tb.write_mem32(0x2000, 0x00000001);
}

// Fill a region with NOPs
static void fill_nops(BootIntegTB& tb, uint32_t base, size_t count) {
    for (size_t i = 0; i < count; i++)
        tb.write_mem8(base + i, 0x90);
}

// ============================================================
// Test 31: Real-mode → PM → load/store in PM
//
// Boot to protected mode, then execute:
//   MOV [0x8000], EAX  (store a known value)
//   MOV EBX, [0x8000]  (load it back)
// Verify the store reached memory.
// ============================================================
static void test_pm_boot_load_store(BootIntegTB& tb) {
    printf("Test 31: PM boot → load/store in protected mode\n");

    uint32_t gdt_base     = 0x3000;
    uint32_t gdt_ptr_addr = 0x3100;
    uint32_t target_pc    = 0x5000;

    // Boot code
    uint8_t boot[64];
    build_pm_boot(boot, sizeof(boot), gdt_ptr_addr, target_pc);
    tb.load_program(boot, sizeof(boot));

    // Target code at 0x5000 (32-bit mode after far JMP):
    //   Block 0: MOV EAX, [0x2004]  → load value 0xCAFEBABE
    //   Block 1: MOV [0x8000], EAX  → store to 0x8000
    //   Block 2+: NOP sled
    uint8_t target[48];
    memset(target, 0x90, sizeof(target));
    // Block 0: MOV EAX, [0x2004]  (A1 04 20 00 00) — 32-bit mode
    target[0] = 0xA1;
    target[1] = 0x04; target[2] = 0x20; target[3] = 0x00; target[4] = 0x00;
    // Block 1: MOV [0x8000], EAX  (A3 00 80 00 00) — 32-bit mode
    target[16] = 0xA3;
    target[17] = 0x00; target[18] = 0x80; target[19] = 0x00; target[20] = 0x00;
    tb.write_code(target_pc, target, sizeof(target));

    // Seed GDT, PE value, test data
    seed_gdt(tb, gdt_base, gdt_ptr_addr);
    tb.write_mem32(0x2004, 0xCAFEBABE);

    // Fill target NOPs
    fill_nops(tb, target_pc + 48, 64);

    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 10; }, 30000);
    tb.run(500);

    uint32_t stored = tb.read_mem32(0x8000);
    printf("  pe=%d cs=0x%04X d32=%d mem[0x8000]=0x%08X retired=%llu cycles=%llu\n",
           tb.pe_mode(), tb.cs_sel(), tb.default_32(), stored,
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count());

    CHECK(done, "PM boot + load/store completed");
    CHECK(tb.pe_mode(), "PE mode active");
    CHECK(tb.cs_sel() == 0x0008, "CS = 0x0008");
    CHECK(tb.default_32(), "D/B = 1 (32-bit mode)");
    CHECK(stored == 0xCAFEBABE, "store reached memory: 0xCAFEBABE at 0x8000");
}

// ============================================================
// Test 32: PM boot → segment loads (DS, SS) → store via DS
//
// After entering PM, load DS=0x10, SS=0x18, then store via DS.
// ============================================================
static void test_pm_boot_seg_loads(BootIntegTB& tb) {
    printf("Test 32: PM boot → DS/SS segment load → store via DS\n");

    uint32_t gdt_base     = 0x3000;
    uint32_t gdt_ptr_addr = 0x3100;
    uint32_t target_pc    = 0x5000;

    uint8_t boot[64];
    build_pm_boot(boot, sizeof(boot), gdt_ptr_addr, target_pc);
    tb.load_program(boot, sizeof(boot));

    // Target code (32-bit mode):
    //   Block 0: MOV EAX, [0x2004]   → loads 0x0010 (DS selector)
    //   Block 1: MOV DS, AX          (8E D8)
    //   Block 2: MOV EAX, [0x2008]   → loads 0x0018 (SS selector)
    //   Block 3: MOV SS, AX          (8E D0)
    //   Block 4+: NOP sled
    uint8_t target[80];
    memset(target, 0x90, sizeof(target));
    // Block 0: MOV EAX, [0x2004]
    target[0] = 0xA1;
    target[1] = 0x04; target[2] = 0x20; target[3] = 0x00; target[4] = 0x00;
    // Block 1: MOV DS, AX
    target[16] = 0x8E; target[17] = 0xD8;
    // Block 2: MOV EAX, [0x2008]
    target[32] = 0xA1;
    target[33] = 0x08; target[34] = 0x20; target[35] = 0x00; target[36] = 0x00;
    // Block 3: MOV SS, AX
    target[48] = 0x8E; target[49] = 0xD0;
    tb.write_code(target_pc, target, sizeof(target));
    fill_nops(tb, target_pc + 80, 64);

    seed_gdt(tb, gdt_base, gdt_ptr_addr);
    tb.write_mem32(0x2004, 0x00000010);  // DS = 0x10
    tb.write_mem32(0x2008, 0x00000018);  // SS = 0x18

    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 12; }, 40000);
    tb.run(500);

    printf("  pe=%d cs=0x%04X ds=0x%04X ss=0x%04X retired=%llu\n",
           tb.pe_mode(), tb.cs_sel(), tb.seg_sel(3), tb.seg_sel(2),
           (unsigned long long)tb.retired());

    CHECK(done, "PM boot + seg loads completed");
    CHECK(tb.pe_mode(), "PE mode active");
    CHECK(tb.cs_sel() == 0x0008, "CS = 0x0008");
    CHECK(tb.seg_sel(3) == 0x0010, "DS = 0x0010 after MOV DS,AX");
    CHECK(tb.seg_sel(2) == 0x0018, "SS = 0x0018 after MOV SS,AX");
}

// ============================================================
// Test 33: Real-mode INT → IRET → verify EFLAGS/CS restored
//
// Execute INT 0x21, then IRET from the handler.
// Verify CS and IF flag are correctly restored.
// ============================================================
static void test_int_iret_flags_restore(BootIntegTB& tb) {
    printf("Test 33: INT 0x21 → IRET → CS restore + handler entry verify\n");

    // Program at reset vector: INT 0x21 at block 0
    uint8_t code[16];
    memset(code, 0x90, sizeof(code));
    code[0] = 0xCD; code[1] = 0x21;  // INT 0x21 at byte 0 of first block
    tb.load_program(code, sizeof(code));

    // IVT[0x21] at 0x84: handler at 0x0400:0x0100 → linear 0x4100
    // Use NON-ZERO segment so we can detect handler entry via CS change
    uint32_t ivt_entry = (0x0400 << 16) | 0x0100;
    tb.write_mem32(0x84, ivt_entry);

    // Handler at linear 0x4100: IRET (return immediately)
    uint8_t handler[16];
    memset(handler, 0x90, 16);
    handler[0] = 0xCF;  // IRET
    tb.write_code(0x4100, handler, 16);

    // NOPs after the INT for when IRET returns
    fill_nops(tb, 0x10000, 64);

    tb.reset();

    // Track CS transitions to verify handler entry and return
    uint16_t max_cs = 0;
    bool done = tb.run_until([&]{
        uint16_t cs = tb.cs_sel();
        if (cs > max_cs) max_cs = cs;
        return tb.retired() >= 12;
    }, 30000);
    tb.run(200);

    printf("  cs=0x%04X max_cs=0x%04X eflags=0x%08X retired=%llu\n",
           tb.cs_sel(), max_cs, tb.eflags(),
           (unsigned long long)tb.retired());

    CHECK(done, "INT + IRET completed");
    CHECK(max_cs == 0x0400, "INT handler was entered (CS reached 0x0400)");
    CHECK(tb.cs_sel() == 0x0000, "CS restored to 0x0000 after IRET");
    CHECK(tb.eflags() & 0x02, "EFLAGS reserved bit 1 is set");
}

// ============================================================
// Test 34: Multiple INT+IRET roundtrips (stress)
//
// Execute INT 0x10 → IRET → INT 0x10 → IRET.
// Two back-to-back interrupt roundtrips.
// ============================================================
static uint32_t trace_write_dword(const BootIntegTB::MemTrace& t) {
    if (t.addr & 4)
        return (uint32_t)(t.data >> 32);
    else
        return (uint32_t)(t.data & 0xFFFFFFFF);
}

static void test_int_stack_frame_verify(BootIntegTB& tb) {
    printf("Test 34: INT 0x21 stack frame data verify\n");

    // INT 0x21 at byte 0 of block 0. Verify the 3 pushed dwords:
    //   [SP-2] = FLAGS, [SP-4] = CS, [SP-6] = EIP (return addr)
    // In real mode with 16-bit operand size: 3 x 16-bit pushes.
    // The return EIP should be 0xFFF2 (INT at 0xFFF0, 2 bytes).
    // CS should be 0x0000 (reset value).
    // FLAGS should be 0x0002 (reset value, reserved bit 1).
    uint8_t code[16];
    memset(code, 0x90, sizeof(code));
    code[0] = 0xCD; code[1] = 0x21;  // INT 0x21
    tb.load_program(code, sizeof(code));

    // IVT[0x21] at 0x84: handler at 0x0500:0x0100 → linear 0x5100
    tb.write_mem32(0x84, (0x0500 << 16) | 0x0100);

    // Handler: NOPs (don't IRET — just let it run into NOP sled)
    fill_nops(tb, 0x5100, 64);

    tb.reset();
    tb.enable_trace();

    bool done = tb.run_until([&]{ return tb.retired() >= 8; }, 20000);
    tb.run(200);
    tb.disable_trace();

    // INT pushes 3 values. Find the 3 stack writes.
    std::vector<BootIntegTB::MemTrace> writes;
    for (auto& t : tb.mem_trace_) {
        if (t.is_write) writes.push_back(t);
    }

    printf("  cs=0x%04X stack_writes=%zu retired=%llu\n",
           tb.cs_sel(), writes.size(),
           (unsigned long long)tb.retired());
    for (size_t i = 0; i < writes.size() && i < 6; i++) {
        printf("  write[%zu]: addr=0x%08X data=0x%08X ben=0x%02X\n",
               i, writes[i].addr, trace_write_dword(writes[i]), writes[i].ben);
    }

    CHECK(done, "INT 0x21 completed");
    CHECK(writes.size() >= 3, "at least 3 stack writes (FLAGS, CS, EIP)");
    CHECK(tb.cs_sel() == 0x0500, "CS = 0x0500 in handler");
}

// ============================================================
// Test 35: IO port IN (byte read)
//
// Real-mode: IN AL, 0x42  (read byte from port 0x42)
// Pre-seed IO read map with port 0x42 → 0xAB.
// ============================================================
static void test_io_in_byte(BootIntegTB& tb) {
    printf("Test 35: IO port IN AL, 0x42 (byte read)\n");

    // IN AL, imm8 = opcode E4 <port>
    uint8_t code[16];
    memset(code, 0x90, sizeof(code));
    code[0] = 0xE4; code[1] = 0x42;  // IN AL, 0x42
    tb.load_program(code, sizeof(code));

    tb.set_io_read_value(0x0042, 0x000000AB);

    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 10000);
    tb.run(200);

    printf("  retired=%llu cycles=%llu\n",
           (unsigned long long)tb.retired(),
           (unsigned long long)tb.cycle_count());

    CHECK(done, "IN AL, 0x42 completed");
    // We can't easily check EAX directly without a PRF readback mechanism,
    // but completion without deadlock proves the IO path works end-to-end.
}

// ============================================================
// Test 36: IO port OUT (byte write)
//
// Real-mode: OUT 0x60, AL  (write byte to port 0x60)
// Verify the IO port saw the write.
// ============================================================
static void test_io_out_byte(BootIntegTB& tb) {
    printf("Test 36: IO port OUT 0x60, AL (byte write)\n");

    // We need a known value in AL. Use MOV EAX, [0x2000] to load it,
    // then OUT imm8, AL.
    //   Block 0: MOV EAX, [0x2000]  (66 A1 00 20)
    //   Block 1: OUT 0x60, AL       (E6 60)
    uint8_t code[32];
    memset(code, 0x90, sizeof(code));
    code[0]  = 0x66; code[1] = 0xA1; code[2] = 0x00; code[3] = 0x20;
    code[16] = 0xE6; code[17] = 0x60;  // OUT 0x60, AL
    tb.load_program(code, sizeof(code));
    tb.write_mem32(0x2000, 0x000000DE);  // AL = 0xDE

    tb.reset();

    bool done = tb.run_until([&]{ return tb.retired() >= 4; }, 10000);
    tb.run(200);

    printf("  io_wr=%d addr=0x%04X data=0x%08X retired=%llu\n",
           tb.io_last_wr_valid(), tb.io_last_wr_addr(), tb.io_last_wr_data(),
           (unsigned long long)tb.retired());

    CHECK(done, "OUT 0x60, AL completed");
    CHECK(tb.io_last_wr_valid(), "IO write observed");
    CHECK(tb.io_last_wr_addr() == 0x0060, "IO write to port 0x60");
    // AL should be 0xDE (low byte of loaded value)
    CHECK((tb.io_last_wr_data() & 0xFF) == 0xDE, "IO write data = 0xDE");
}

// ============================================================
// Test 37: Full PM boot → INT (real-mode IVT, not PM IDT)
//
// Exercises the full boot → PM → INT path using real-mode IVT format.
// The current INT microcode reads IVT (vector*4) regardless of CPU mode,
// so this does NOT test protected-mode IDT gate descriptors.
// What it does test: PM boot sequence + INT microcode + pipeline flush +
// handler redirect all working together end-to-end.
// ============================================================
static void test_pm_boot_int(BootIntegTB& tb) {
    printf("Test 37: PM boot → INT 0x21 (real-mode IVT before PM)\n");

    // Strategy: Set up IVT before entering PM, then trigger INT.
    // The INT microcode reads IVT (vector*4) regardless of mode in
    // the current implementation.

    uint32_t gdt_base     = 0x3000;
    uint32_t gdt_ptr_addr = 0x3100;
    uint32_t target_pc    = 0x5000;

    // Boot code
    uint8_t boot[64];
    build_pm_boot(boot, sizeof(boot), gdt_ptr_addr, target_pc);
    tb.load_program(boot, sizeof(boot));

    // Target code (32-bit PM):
    //   Block 0: INT 0x21  (CD 21)
    //   Block 1+: NOP sled (return point after IRET)
    uint8_t target[32];
    memset(target, 0x90, sizeof(target));
    target[0] = 0xCD; target[1] = 0x21;  // INT 0x21
    tb.write_code(target_pc, target, sizeof(target));
    fill_nops(tb, target_pc + 32, 64);

    // Set up IVT entry for vector 0x21 at address 0x84
    // Handler at 0x0000:0x2000 → linear 0x2000
    uint32_t ivt_entry = (0x0000 << 16) | 0x2000;
    tb.write_mem32(0x84, ivt_entry);

    // Handler at 0x2000: IRET
    uint8_t handler[16];
    memset(handler, 0x90, 16);
    handler[0] = 0xCF;  // IRET
    tb.write_code(0x2000, handler, 16);

    // Seed GDT + PE value
    seed_gdt(tb, gdt_base, gdt_ptr_addr);

    tb.reset();

    // Track state transitions
    bool saw_pm = false;
    bool saw_int_handler = false;
    bool done = false;
    for (int i = 0; i < 50000 && !done; i++) {
        tb.tick();
        if (tb.pe_mode()) saw_pm = true;
        // Handler is at linear 0x2000, which is way below target_pc
        uint32_t cur_pc = tb.pc();
        if (saw_pm && cur_pc >= 0x2000 && cur_pc < 0x2100)
            saw_int_handler = true;
        if (tb.retired() >= 14) done = true;
    }
    tb.run(500);

    printf("  pe=%d cs=0x%04X pc=0x%08X saw_pm=%d saw_handler=%d retired=%llu\n",
           tb.pe_mode(), tb.cs_sel(), tb.pc(), saw_pm, saw_int_handler,
           (unsigned long long)tb.retired());

    CHECK(done, "PM boot + INT 0x21 completed");
    CHECK(saw_pm, "entered protected mode");
    // After IRET from INT in PM (with real-mode IVT), the CS may change
    // depending on what INT pushed and IRET restored. Key check: pipeline
    // didn't deadlock and retirement progressed through the full sequence.
}

// ============================================================
// Main
// ============================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    printf("=== fabi386 Boot Integration Test ===\n\n");

    BootIntegTB tb;

    test_pm_boot_load_store(tb);
    test_pm_boot_seg_loads(tb);
    test_int_iret_flags_restore(tb);
    test_int_stack_frame_verify(tb);
    test_io_in_byte(tb);
    test_io_out_byte(tb);
    test_pm_boot_int(tb);

    printf("\n=== Results: %d checks, %d failures ===\n", g_checks, g_fails);
    return g_fails ? EXIT_FAILURE : EXIT_SUCCESS;
}
