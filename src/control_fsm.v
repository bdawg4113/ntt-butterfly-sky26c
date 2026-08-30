// -----------------------------------------------------------------------------
// REFERENCE MODEL -- NOT part of the hardened Tiny Tapeout design.
//
// This is the self-contained NTT sequencer with an on-chip coefficient array.
// It is kept because test/Makefile_top verifies it against the Python golden
// model, which is what proves the butterfly and twiddle ROM implement FIPS 203
// Algorithm 9 correctly. It is deliberately absent from info.yaml's
// source_files: as flip-flops the 256x12 array synthesises to 6144 registers
// (two combinational read ports force Yosys to duplicate the storage), which
// exceeds even the largest 8x2 tile. The taped-out design streams coefficients
// over the pins instead -- see src/bfu_stream.v.
// -----------------------------------------------------------------------------

// control_fsm.v -- address sequencer for the ML-KEM forward NTT
//
// Issues one butterfly per clock into the pipelined datapath.
//
// FIPS 203 Algorithm 9 walks (len, start, j) with len = 128, 64, ... 2. Every
// butterfly in a given stage touches the disjoint address pair (j, j+len), so
// within a stage no butterfly can read a value another one is still writing.
// That is what makes full-rate issue safe: the pipeline only has to be drained
// at a stage boundary, where stage s+1 reads what stage s wrote.
//
//   S_ISSUE : one (j, j+len, k) pair per clock, issue held high
//   S_DRAIN : BF_LATENCY idle clocks so the stage's last write lands before
//             the next stage starts reading
//
// Cost: 7 stages x (128 issues + drain) ~= 940 clocks, against 3586 for the
// old four-clocks-per-butterfly sequencer.
//
// Read addresses are combinational off the loop counters so the memory read
// and the multiplier's first stage happen in the issue cycle. Write addresses
// are the same values delayed by BF_LATENCY, so they line up with the results
// coming out of the butterfly; the write strobe is the butterfly's out_valid.

`default_nettype none

module control_fsm #(
    // Clocks from "operands issued" to "a_out/b_out valid" in butterfly.v.
    // Must match that module: 3 for mod_mult + 1 for the mod_add/mod_sub stage.
    parameter integer BF_LATENCY = 4
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,

    // issue side -- combinational, valid in the same cycle as issue
    output wire [7:0] r_addr_a,
    output wire [7:0] r_addr_b,
    output wire [6:0] k_idx,
    output reg        issue,

    // write side -- issue addresses delayed to meet the butterfly results
    output wire [7:0] w_addr_a,
    output wire [7:0] w_addr_b,

    output reg        done
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_ISSUE = 2'd1,
                     S_DRAIN = 2'd2,
                     S_DONE  = 2'd3;

    reg [1:0] state;
    reg [7:0] len;
    reg [7:0] start_idx;
    reg [7:0] j;
    reg [6:0] k;
    reg [2:0] drain_cnt;

    // ---- the butterfly being issued this cycle ---------------------------
    assign r_addr_a = j;
    assign r_addr_b = j + len;
    assign k_idx    = k;

    // ---- loop-boundary tests ---------------------------------------------
    // start_idx + 2*len must reach 256, so evaluate it in 9 bits.
    wire [8:0] next_start    = {1'b0, start_idx} + {1'b0, len} + {1'b0, len};
    wire       last_in_block = (j == (start_idx + len - 8'd1));
    wire       last_block    = (next_start >= 9'd256);
    wire       last_stage    = (len <= 8'd2);

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            len       <= 8'd128;
            start_idx <= 8'd0;
            j         <= 8'd0;
            k         <= 7'd1;
            issue     <= 1'b0;
            done      <= 1'b0;
            drain_cnt <= 3'd0;
        end else begin
            issue <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        len       <= 8'd128;
                        start_idx <= 8'd0;
                        j         <= 8'd0;
                        k         <= 7'd1;
                        done      <= 1'b0;   // sticky until the next start
                        issue     <= 1'b1;   // first pair is already on r_addr_*
                        state     <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    issue <= 1'b1;
                    if (!last_in_block) begin
                        // next butterfly in this block
                        j <= j + 8'd1;
                    end else if (!last_block) begin
                        // next block of the same stage: new twiddle, no drain
                        // needed because the address ranges are disjoint
                        start_idx <= next_start[7:0];
                        j         <= next_start[7:0];
                        k         <= k + 7'd1;
                    end else begin
                        // last butterfly of the stage went out this cycle
                        issue     <= 1'b0;
                        k         <= k + 7'd1;
                        drain_cnt <= BF_LATENCY[2:0];
                        state     <= S_DRAIN;
                    end
                end

                S_DRAIN: begin
                    if (drain_cnt != 3'd0) begin
                        drain_cnt <= drain_cnt - 3'd1;
                    end else if (last_stage) begin
                        state <= S_DONE;
                    end else begin
                        len       <= len >> 1;
                        start_idx <= 8'd0;
                        j         <= 8'd0;
                        issue     <= 1'b1;
                        state     <= S_ISSUE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- write-address delay line ----------------------------------------
    // Same depth as the butterfly latency, so w_addr_* present the issue
    // addresses on exactly the cycle their results appear.
    reg [8*BF_LATENCY-1:0] wa_pipe;
    reg [8*BF_LATENCY-1:0] wb_pipe;

    always @(posedge clk) begin
        if (rst) begin
            wa_pipe <= {(8*BF_LATENCY){1'b0}};
            wb_pipe <= {(8*BF_LATENCY){1'b0}};
        end else begin
            wa_pipe <= {wa_pipe[8*(BF_LATENCY-1)-1:0], r_addr_a};
            wb_pipe <= {wb_pipe[8*(BF_LATENCY-1)-1:0], r_addr_b};
        end
    end

    assign w_addr_a = wa_pipe[8*BF_LATENCY-1 -: 8];
    assign w_addr_b = wb_pipe[8*BF_LATENCY-1 -: 8];

endmodule

`default_nettype wire
