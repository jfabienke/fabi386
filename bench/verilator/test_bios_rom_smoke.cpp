/*
 * fabi386: BIOS ROM smoke test
 * -----------------------------
 * Loads the exact same diagnostic ROM image that the hardware build uses
 * (asm/diagnostic.hex → memory at 0xFC000..0xFFFFF) and runs the CPU core
 * long enough to see it reach the OUT instruction at port 0x378.
 *
 * This mirrors the hardware symptom without a Quartus build in between:
 *   - Hardware: LEDR[2]/LEDR[4] blinking → clocks OK, reset released, but
 *     LEDR[0] stays dark → CPU never writes to 0x378.
 *   - Simulation: we can watch every internal signal (VCD) to see where
 *     the chain breaks.
 *
 * Pass criterion: CPU writes anything to I/O port 0x378 within N cycles.
 * On failure, the VCD shows exactly where the CPU got stuck.
 */

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

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
        printf("  FAIL: %s (line %d)\n", msg, __LINE__);      \
        g_fails++;                                            \
    }                                                         \
} while(0)

// ============================================================
// Minimal testbench reusing the BootIntegTB pattern
// ============================================================
class BiosSmokeTB {
public:
    BiosSmokeTB()
        : top_(std::make_unique<Vf386_ooo_core_top>())
        , trace_(std::make_unique<VerilatedVcdC>())
        , cycle_(0)
        , retired_(0)
        , trace_time_(0)
        , data_ack_pending_(false)
        , data_ack_rdata_(0)
        , ack_hold_(0)
        , io_ack_pending_(false)
        , io_writes_(0)
        , io_0x378_writes_(0)
        , io_wr_log_()
    {
        Verilated::traceEverOn(true);
        top_->trace(trace_.get(), 99);
        trace_->open("tb_bios_rom_smoke.vcd");
    }

    ~BiosSmokeTB() { trace_->close(); }

    // Load a raw binary file into memory at a given byte address.
    bool load_bin(const std::string& path, uint32_t base) {
        std::ifstream f(path, std::ios::binary);
        if (!f) {
            printf("  ERROR: cannot open %s\n", path.c_str());
            return false;
        }
        std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(f)),
                                    std::istreambuf_iterator<char>());
        for (size_t i = 0; i < bytes.size(); i++)
            mem_.write8(base + i, bytes[i]);
        printf("  loaded %zu bytes at 0x%08X\n", bytes.size(), base);
        return true;
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

        if (ack_hold_ > 0) {
            ack_hold_--;
            if (ack_hold_ == 0) {
                top_->mem_ack = 0;
                top_->mem_gnt = 0;
            }
        }
        if (data_ack_pending_) {
            top_->mem_ack   = 1;
            top_->mem_gnt   = 1;
            top_->mem_rdata = data_ack_rdata_;
            data_ack_pending_ = false;
            ack_hold_ = 1;
        }

        if (io_ack_pending_) {
            top_->io_port_ack   = 1;
            top_->io_port_rdata = 0;
            io_ack_pending_ = false;
        } else {
            top_->io_port_ack = 0;
        }

        service_fetch();
        service_data_mem();
        service_io_port();

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

    uint64_t cycles()          const { return cycle_; }
    uint64_t retired()         const { return retired_; }
    uint64_t io_writes()       const { return io_writes_; }
    uint64_t io_0x378_writes() const { return io_0x378_writes_; }

    uint32_t pc() const {
        return top_->rootp->f386_ooo_core_top__DOT__pc_current;
    }

    void print_io_log(size_t max = 16) const {
        size_t n = std::min(io_wr_log_.size(), max);
        printf("  io write log (%zu events, showing %zu):\n",
               io_wr_log_.size(), n);
        for (size_t i = 0; i < n; i++) {
            const auto& e = io_wr_log_[i];
            printf("    cycle %6lu  port 0x%04X = 0x%08X\n",
                   (unsigned long)e.cycle, e.port, e.data);
        }
    }

private:
    std::unique_ptr<Vf386_ooo_core_top> top_;
    std::unique_ptr<VerilatedVcdC>      trace_;
    uint64_t cycle_;
    uint64_t retired_;
    uint64_t trace_time_;
    MemoryModel mem_;
    bool     data_ack_pending_;
    uint64_t data_ack_rdata_;
    int      ack_hold_;
    bool     io_ack_pending_;
    uint64_t io_writes_;
    uint64_t io_0x378_writes_;
    struct IoEvent { uint64_t cycle; uint16_t port; uint32_t data; };
    std::vector<IoEvent> io_wr_log_;

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
                for (int i = 0; i < 8; i++) {
                    if (ben & (1 << i))
                        mem_.write8(base + i, (wdata >> (i * 8)) & 0xFF);
                }
            } else {
                uint64_t rdata = 0;
                for (int i = 0; i < 8; i++)
                    rdata |= (uint64_t)mem_.read8(base + i) << (i * 8);
                data_ack_rdata_ = rdata;
            }
            data_ack_pending_ = true;
        }
    }

    void service_io_port() {
        if (top_->io_port_rd && !io_ack_pending_) {
            io_ack_pending_ = true;
        } else if (top_->io_port_wr && !io_ack_pending_) {
            uint16_t port = top_->io_port_addr;
            uint32_t data = top_->io_port_wdata;
            io_writes_++;
            if (port == 0x0378) io_0x378_writes_++;
            if (io_wr_log_.size() < 64)
                io_wr_log_.push_back({cycle_, port, data});
            io_ack_pending_ = true;
        }
    }
};

// ============================================================
// main
// ============================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const std::string bin_path =
        (argc > 1) ? argv[1] : "../../asm/diagnostic.bin";

    // fabi386 starts fetching at linear 0x0000FFF0 (see f386_ooo_core_top.sv),
    // not the canonical x86 0xFFFFFFF0. The ROM is assembled with ORG 0xC000
    // so loading it at physical 0xC000 places the reset vector at 0xFFF0.
    const uint32_t rom_base  = 0xC000;
    const uint64_t max_cycles = 2'000'000;   // ~60 ms at a simulated 33 MHz

    printf("=== BIOS ROM smoke test ===\n");
    printf("  rom image : %s\n", bin_path.c_str());
    printf("  load base : 0x%08X\n", rom_base);
    printf("  max cycles: %lu\n\n", (unsigned long)max_cycles);

    BiosSmokeTB tb;

    if (!tb.load_bin(bin_path, rom_base)) {
        printf("FAIL: could not load ROM image\n");
        return 1;
    }

    tb.reset();
    printf("  reset done, starting fetch…\n\n");

    const uint64_t status_every = 200'000;
    uint64_t last_status = 0;

    bool hit = tb.run_until([&]() {
        if (tb.cycles() - last_status >= status_every) {
            last_status = tb.cycles();
            printf("  cycle %8lu  pc=0x%08X  retired=%lu  ios=%lu  io_0x378=%lu\n",
                   (unsigned long)tb.cycles(),
                   tb.pc(),
                   (unsigned long)tb.retired(),
                   (unsigned long)tb.io_writes(),
                   (unsigned long)tb.io_0x378_writes());
        }
        return tb.io_0x378_writes() > 0;
    }, max_cycles);

    printf("\n=== result ===\n");
    printf("  cycles run : %lu\n", (unsigned long)tb.cycles());
    printf("  retired    : %lu\n", (unsigned long)tb.retired());
    printf("  io writes  : %lu (any port)\n", (unsigned long)tb.io_writes());
    printf("  io 0x378   : %lu\n", (unsigned long)tb.io_0x378_writes());
    printf("  final pc   : 0x%08X\n", tb.pc());

    tb.print_io_log();

    CHECK(hit, "CPU wrote to I/O port 0x378 within cycle budget");
    CHECK(tb.retired() > 0, "CPU retired at least one instruction");

    printf("\n  checks=%d fails=%d\n", g_checks, g_fails);
    return g_fails == 0 ? 0 : 1;
}
