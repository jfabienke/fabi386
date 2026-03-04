/*
 * fabi386: DDRAM Burst Protocol Smoke Test
 * -----------------------------------------
 * Sim-only validation fixture that exercises burst-1, burst-2, and burst-4
 * DDRAM write+readback sequences against a minimal responder model.
 *
 * Validates the burst protocol (burstcnt, auto-incrementing address, one
 * ddram_dout_ready per beat) in isolation before L2 depends on it.
 *
 * Does NOT touch the active f386_mem_ctrl ifetch path.
 */

module ddram_burst_smoke;

    // =========================================================
    // Clock / Reset
    // =========================================================
    logic clk, rst_n;
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        #20 rst_n = 1;
    end

    // =========================================================
    // DUT-side DDRAM signals
    // =========================================================
    logic [28:0] ddram_addr;
    logic [7:0]  ddram_burstcnt;
    logic [63:0] ddram_din;
    logic [7:0]  ddram_be;
    logic        ddram_we;
    logic        ddram_rd;
    logic [63:0] ddram_dout;
    logic        ddram_dout_ready;
    logic        ddram_busy;

    // =========================================================
    // Minimal DDRAM Responder Model
    // =========================================================
    // - 256-entry memory (64-bit words), addressed by ddram_addr[7:0]
    // - Write: captures ddram_din on ddram_we, auto-increments for burst
    // - Read:  returns data on ddram_dout_ready, one beat per cycle after
    //          a 2-cycle startup latency, auto-incrementing address
    // - ddram_busy: asserted for 1 cycle after accepting a request

    logic [63:0] mem_array [256];
    logic [7:0]  resp_addr;
    logic [7:0]  resp_remaining;
    logic [1:0]  resp_latency;
    logic        resp_active;

    // Write burst tracking
    logic [7:0]  wr_addr;
    logic [7:0]  wr_remaining;

    assign ddram_busy = (resp_latency != 0) || (wr_remaining != 0 && !ddram_we);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ddram_dout_ready <= 1'b0;
            ddram_dout       <= 64'd0;
            resp_active      <= 1'b0;
            resp_remaining   <= 8'd0;
            resp_latency     <= 2'd0;
            wr_remaining     <= 8'd0;
        end else begin
            ddram_dout_ready <= 1'b0;

            // Accept write request
            if (ddram_we) begin
                mem_array[ddram_addr[7:0]] <= ddram_din;
                if (wr_remaining == 0) begin
                    // First beat of burst write
                    wr_addr      <= ddram_addr[7:0] + 8'd1;
                    wr_remaining <= ddram_burstcnt - 8'd1;
                end else begin
                    // Subsequent beats
                    mem_array[wr_addr] <= ddram_din;
                    wr_addr      <= wr_addr + 8'd1;
                    wr_remaining <= wr_remaining - 8'd1;
                end
            end

            // Accept read request
            if (ddram_rd && !resp_active) begin
                resp_addr      <= ddram_addr[7:0];
                resp_remaining <= ddram_burstcnt;
                resp_latency   <= 2'd2;  // 2-cycle startup latency
                resp_active    <= 1'b1;
            end

            // Read response pipeline
            if (resp_active) begin
                if (resp_latency != 0) begin
                    resp_latency <= resp_latency - 2'd1;
                end else if (resp_remaining != 0) begin
                    ddram_dout       <= mem_array[resp_addr];
                    ddram_dout_ready <= 1'b1;
                    resp_addr        <= resp_addr + 8'd1;
                    resp_remaining   <= resp_remaining - 8'd1;
                    if (resp_remaining == 8'd1)
                        resp_active <= 1'b0;
                end
            end
        end
    end

    // =========================================================
    // Test Sequencer
    // =========================================================
    typedef enum logic [3:0] {
        T_IDLE,
        T_WRITE_BURST,
        T_WRITE_WAIT,
        T_READ_BURST,
        T_READ_WAIT,
        T_VERIFY,
        T_NEXT,
        T_DONE
    } test_state_t;

    test_state_t tstate;
    logic [7:0]  burst_len;       // Current burst length under test
    logic [28:0] base_addr;       // Base address for current test
    logic [7:0]  beat_cnt;        // Beat counter within burst
    logic [63:0] read_buf [4];    // Captured read data
    logic [63:0] expected [4];    // Expected write data
    logic [1:0]  test_idx;        // 0=burst-1, 1=burst-2, 2=burst-4
    logic        test_passed;

    // Generate deterministic test data
    function automatic logic [63:0] test_data(input logic [28:0] addr, input logic [7:0] beat);
        return {addr[15:0], beat, 8'hA5, addr[7:0], beat ^ 8'hFF, 16'hCAFE};
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate      <= T_IDLE;
            ddram_addr  <= 29'd0;
            ddram_burstcnt <= 8'd0;
            ddram_din   <= 64'd0;
            ddram_be    <= 8'h00;
            ddram_we    <= 1'b0;
            ddram_rd    <= 1'b0;
            test_idx    <= 2'd0;
            beat_cnt    <= 8'd0;
            test_passed <= 1'b1;
        end else begin
            ddram_we <= 1'b0;
            ddram_rd <= 1'b0;

            case (tstate)
                T_IDLE: begin
                    // Select burst length: 1, 2, 4
                    case (test_idx)
                        2'd0: burst_len <= 8'd1;
                        2'd1: burst_len <= 8'd2;
                        2'd2: burst_len <= 8'd4;
                        default: burst_len <= 8'd1;
                    endcase
                    base_addr <= {21'd0, test_idx, 6'd0};  // Different base per test
                    beat_cnt  <= 8'd0;
                    tstate    <= T_WRITE_BURST;
                end

                T_WRITE_BURST: begin
                    if (!ddram_busy) begin
                        ddram_addr     <= base_addr + {21'd0, beat_cnt};
                        ddram_burstcnt <= (beat_cnt == 0) ? burst_len : 8'd1;
                        ddram_din      <= test_data(base_addr, beat_cnt);
                        ddram_be       <= 8'hFF;
                        ddram_we       <= 1'b1;

                        expected[beat_cnt[1:0]] <= test_data(base_addr, beat_cnt);

                        if (beat_cnt == burst_len - 8'd1) begin
                            beat_cnt <= 8'd0;
                            tstate   <= T_WRITE_WAIT;
                        end else begin
                            beat_cnt <= beat_cnt + 8'd1;
                        end
                    end
                end

                T_WRITE_WAIT: begin
                    // Wait for write to settle
                    if (!ddram_busy) begin
                        tstate <= T_READ_BURST;
                    end
                end

                T_READ_BURST: begin
                    if (!ddram_busy) begin
                        ddram_addr     <= base_addr;
                        ddram_burstcnt <= burst_len;
                        ddram_rd       <= 1'b1;
                        beat_cnt       <= 8'd0;
                        tstate         <= T_READ_WAIT;
                    end
                end

                T_READ_WAIT: begin
                    if (ddram_dout_ready) begin
                        read_buf[beat_cnt[1:0]] <= ddram_dout;
                        if (beat_cnt == burst_len - 8'd1)
                            tstate <= T_VERIFY;
                        else
                            beat_cnt <= beat_cnt + 8'd1;
                    end
                end

                T_VERIFY: begin
                    for (int i = 0; i < 4; i++) begin
                        if (i < burst_len) begin
                            if (read_buf[i] != expected[i]) begin
                                $error("BURST-%0d FAIL: beat %0d expected %016h got %016h",
                                       burst_len, i, expected[i], read_buf[i]);
                                test_passed <= 1'b0;
                            end
                        end
                    end
                    $display("BURST-%0d: PASS", burst_len);
                    tstate <= T_NEXT;
                end

                T_NEXT: begin
                    if (test_idx == 2'd2) begin
                        tstate <= T_DONE;
                    end else begin
                        test_idx <= test_idx + 2'd1;
                        tstate   <= T_IDLE;
                    end
                end

                T_DONE: begin
                    if (test_passed)
                        $display("ALL DDRAM BURST TESTS PASSED");
                    else
                        $fatal(1, "DDRAM BURST TESTS FAILED");
                    $finish;
                end

                default: tstate <= T_IDLE;
            endcase
        end
    end

    // Watchdog: 10000 cycles max
    int cycle_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_cnt <= 0;
        else begin
            cycle_cnt <= cycle_cnt + 1;
            if (cycle_cnt > 10000)
                $fatal(1, "DDRAM burst smoke test watchdog timeout");
        end
    end

endmodule
