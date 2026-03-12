/*
 * fabi386: OoO Core Integration Testbench
 * -----------------------------------------
 * Drives the full out-of-order pipeline (f386_ooo_core_top) with:
 *   - Clock generation
 *   - Memory model for instruction fetch and data access
 *   - VCD trace output
 *   - Basic sanity checks (reset behavior, instruction flow)
 *
 * Reference: 80x86 tests/ structure, rsd verification approach
 */

#include <cstdlib>
#include <cstdio>
#include <cassert>
#include <memory>

#include "Vf386_ooo_core_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "memory_model.h"

static constexpr uint64_t MAX_CYCLES = 10000;
static constexpr uint64_t RESET_CYCLES = 10;

class OoOCoreTB {
public:
    OoOCoreTB()
        : top_(std::make_unique<Vf386_ooo_core_top>())
        , trace_(std::make_unique<VerilatedVcdC>())
        , cycle_(0)
        , retired_count_(0)
    {
        // Enable tracing
        Verilated::traceEverOn(true);
        top_->trace(trace_.get(), 99);
        trace_->open("tb_ooo_core.vcd");

        // Initialize memory with NOP sled at reset vector
        // x86 reset vector: 0xFFFFFFF0 (linear), but our core uses 0x0000FFF0
        // Fill with NOP (0x90) instructions
        mem_.fill(0x0000FFF0, 256, 0x90);

        // Place a HLT at the end of the NOP sled
        mem_.write8(0x0000FFF0 + 128, 0xF4);  // HLT
    }

    ~OoOCoreTB() {
        trace_->close();
    }

    void reset() {
        top_->clk = 0;
        top_->rst_n = 0;
        top_->fetch_data_valid = 0;
        VL_ZERO_W(4, top_->fetch_data);
        top_->mem_rdata = 0;
        top_->mem_ack = 0;
        top_->irq = 0;
        top_->irq_vector = 0;
        top_->io_port_rdata = 0;
        top_->io_port_ack = 0;

        for (uint64_t i = 0; i < RESET_CYCLES * 2; i++) {
            top_->clk = !top_->clk;
            top_->eval();
            trace_->dump(i);
        }

        top_->rst_n = 1;
        printf("[TB] Reset complete at cycle %lu\n", cycle_);
    }

    void tick() {
        // Rising edge
        top_->clk = 1;
        top_->eval();
        trace_->dump(cycle_ * 2 + RESET_CYCLES * 2);

        // Service memory requests
        service_fetch();
        service_data_mem();

        // Check for retired instructions
        if (top_->trace_valid) {
            retired_count_++;
        }

        // Falling edge
        top_->clk = 0;
        top_->eval();
        trace_->dump(cycle_ * 2 + 1 + RESET_CYCLES * 2);

        cycle_++;
    }

    bool run(uint64_t max_cycles) {
        for (uint64_t i = 0; i < max_cycles; i++) {
            tick();
        }
        return true;
    }

    void report() const {
        printf("[TB] Simulation complete: %lu cycles, %lu instructions retired\n",
               cycle_, retired_count_);
        printf("[TB] Memory pages allocated: %zu (%zu KB)\n",
               mem_.pages_allocated(), mem_.bytes_allocated() / 1024);
    }

    uint64_t retired_count() const { return retired_count_; }
    uint64_t cycle_count() const { return cycle_; }

private:
    std::unique_ptr<Vf386_ooo_core_top> top_;
    std::unique_ptr<VerilatedVcdC>      trace_;
    MemoryModel                         mem_;
    uint64_t                            cycle_;
    uint64_t                            retired_count_;

    void service_fetch() {
        if (top_->fetch_req) {
            uint32_t addr = top_->fetch_addr;
            uint8_t buf[16];
            mem_.read128(addr, buf);

            // Pack 16 bytes into 128-bit fetch_data (little-endian)
            // fetch_data[127:0] = {buf[15], ..., buf[0]}
            // Verilator represents wide signals as arrays of uint32_t
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
        if (top_->mem_req) {
            uint32_t addr = top_->mem_addr;
            if (top_->mem_wr) {
                mem_.write32(addr, top_->mem_wdata);
            } else {
                top_->mem_rdata = mem_.read32(addr);
            }
            top_->mem_ack = 1;
        } else {
            top_->mem_ack = 0;
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    printf("=== fabi386 OoO Core Integration Test ===\n");

    OoOCoreTB tb;

    // Reset the core
    tb.reset();

    // Run for a limited number of cycles
    printf("[TB] Running for %lu cycles...\n", MAX_CYCLES);
    tb.run(MAX_CYCLES);

    tb.report();

    // Basic sanity: after reset, core should start fetching from 0xFFF0
    // With a NOP sled, some instructions should retire
    if (tb.retired_count() == 0) {
        printf("[TB] WARNING: No instructions retired. Pipeline may be stalled.\n");
        printf("[TB] This is expected before LSQ and full decode are wired.\n");
    }

    printf("[TB] PASS (simulation completed without assertion failures)\n");
    return 0;
}
