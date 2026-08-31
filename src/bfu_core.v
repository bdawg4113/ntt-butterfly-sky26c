// bfu_core.v -- the arithmetic core of the ML-KEM NTT/INTT accelerator.
//
// A single serial Montgomery multiplier serves every operation, sequenced by a
// small state machine:
//
//  mode  name          a_out              b_out              muls  used by
//  ----  ------------  -----------------  -----------------  ----  --------------
//  000   MODE_CT       a + fqmul(z,b)     a - fqmul(z,b)       1   forward NTT
//  001   MODE_GS       reduce(a + b)      fqmul(z, b - a)      2   inverse NTT
//  010   MODE_FQMUL    fqmul(a, b)        same                 1   scaling, basemul
//  011   MODE_REDUCE   reduce(a)          same                 1   range control
//  100   MODE_ADD      a + b              a - b                0   poly add/sub
//
// All values are signed 16-bit and centred; q = 3329, R = 2^16.
//
// There is no separate Barrett reducer. reduce(x) is fqmul(x, R mod q), which
// equals x*R*R^-1 = x, and Montgomery guarantees |t| < q -- so it returns a
// centred representative without changing the residue, which is exactly what
// Barrett was there for. Folding it onto the shared multiplier removed a whole
// arithmetic unit worth 6,304 um2, a sixth of the area budget.
//
// The forward (Cooley-Tukey) and inverse (Gentleman-Sande) butterflies are the
// same primitive sequenced differently -- CT multiplies then adds, GS adds then
// multiplies -- which is why one core covers both transforms.
//
// This core is multi-cycle, not pipelined: it handles one operation at a time
// and raises busy while doing so. That is the right trade here, because the
// byte-serial pin interface cannot supply operands faster than roughly one set
// per ten clocks, so a one-per-clock datapath would simply idle. Being
// multi-cycle also means operands stay put in the caller's registers for the
// whole operation, so there is no bypass chain and no valid pipeline to keep in
// step -- an entire class of structure, and its bugs, disappears.
//
// Timing: 17 clocks per multiply, so about 19 clocks for a one-multiply mode,
// 36 for MODE_GS, and 1 for MODE_ADD.

`default_nettype none

module bfu_core (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,   // start one operation; ignored while busy
    input  wire        [2:0]  mode,
    input  wire signed [15:0] a,          // must hold steady until out_valid
    input  wire signed [15:0] b,
    input  wire signed [15:0] zeta,
    output reg  signed [15:0] a_out,
    output reg  signed [15:0] b_out,
    output reg                out_valid,  // one-clock pulse
    output wire               busy
);

    localparam [2:0] MODE_CT     = 3'd0,
                     MODE_GS     = 3'd1,
                     MODE_FQMUL  = 3'd2,
                     MODE_REDUCE = 3'd3,
                     MODE_ADD    = 3'd4;

    localparam signed [15:0] R_MOD_Q = 16'sd2285;   // R mod q, the reduction constant

    localparam [1:0] S_IDLE = 2'd0,
                     S_MUL1 = 2'd1,
                     S_MUL2 = 2'd2;

    reg [1:0] state;

    // The caller holds the operands steady, so they are read directly rather
    // than latched again here -- 48 bits of registers this core does not pay for.
    wire signed [15:0] sum  = a + b;
    wire signed [15:0] diff = b - a;

    // ---- the shared serial multiplier ------------------------------------
    // Pass 1 depends on the mode; pass 2 exists only for MODE_GS, where it
    // reduces (a+b) into range.
    wire signed [15:0] fq_x = (state == S_MUL2)     ? sum :
                              (mode == MODE_FQMUL)  ? a   :
                              (mode == MODE_REDUCE) ? a   :
                                                      zeta;

    wire signed [15:0] fq_y = (state == S_MUL2)     ? R_MOD_Q :
                              (mode == MODE_FQMUL)  ? b       :
                              (mode == MODE_REDUCE) ? R_MOD_Q :
                              (mode == MODE_GS)     ? diff    :
                                                      b;

    reg                fq_start;
    wire signed [15:0] fq_c;
    wire               fq_done;
    wire               fq_busy;

    ser_fqmul u_fqmul (
        .clk   (clk),
        .rst   (rst),
        .start (fq_start),
        .a     (fq_x),
        .b     (fq_y),
        .c     (fq_c),
        .done  (fq_done),
        .busy  (fq_busy)
    );

    // first-pass result, needed only by MODE_GS while the second pass runs
    reg signed [15:0] t1;

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            fq_start  <= 1'b0;
            t1        <= 16'sd0;
            a_out     <= 16'sd0;
            b_out     <= 16'sd0;
            out_valid <= 1'b0;
        end else begin
            fq_start  <= 1'b0;
            out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (in_valid) begin
                        if (mode == MODE_ADD) begin
                            // no multiply needed; answer immediately
                            a_out     <= sum;
                            b_out     <= a - b;
                            out_valid <= 1'b1;
                        end else begin
                            fq_start <= 1'b1;
                            state    <= S_MUL1;
                        end
                    end
                end

                S_MUL1: begin
                    if (fq_done) begin
                        t1 <= fq_c;
                        if (mode == MODE_GS) begin
                            // second pass reduces (a+b) into range
                            fq_start <= 1'b1;
                            state    <= S_MUL2;
                        end else begin
                            if (mode == MODE_CT) begin
                                a_out <= a + fq_c;
                                b_out <= a - fq_c;
                            end else begin        // MODE_FQMUL, MODE_REDUCE
                                a_out <= fq_c;
                                b_out <= fq_c;
                            end
                            out_valid <= 1'b1;
                            state     <= S_IDLE;
                        end
                    end
                end

                default: begin      // S_MUL2, MODE_GS only
                    if (fq_done) begin
                        a_out     <= fq_c;   // reduce(a + b)
                        b_out     <= t1;     // fqmul(zeta, b - a)
                        out_valid <= 1'b1;
                        state     <= S_IDLE;
                    end
                end
            endcase
        end
    end

    // the multiplier's own busy line is implied by this core's state
    wire _unused = &{1'b0, fq_busy, 1'b0};

endmodule

`default_nettype wire
