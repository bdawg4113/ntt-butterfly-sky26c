// bfu_core.v -- the arithmetic core of the ML-KEM NTT/INTT accelerator.
//
// One shared Montgomery multiplier and one shared Barrett reducer serve every
// operation. The mode selects how they are wired:
//
//  mode  name          a_out                  b_out               used by
//  ----  ------------  ---------------------  ------------------  --------------
//  000   MODE_CT       a + fqmul(zeta,b)      a - fqmul(zeta,b)   forward NTT
//  001   MODE_GS       barrett(a + b)         fqmul(zeta, b - a)  inverse NTT
//  010   MODE_FQMUL    fqmul(a, b)            same                scaling, basemul
//  011   MODE_BARRETT  barrett(a)             same                range control
//  100   MODE_ADD      a + b                  a - b               poly add/sub
//
// All values are signed 16-bit and centred; q = 3329, R = 2^16.
//
// The forward (Cooley-Tukey) and inverse (Gentleman-Sande) butterflies are the
// same primitive sequenced differently -- CT multiplies then adds, GS adds then
// multiplies -- which is why one arithmetic core covers both transforms.
//
// MODE_FQMUL with b = 1 is a bare montgomery_reduce, which is how the host
// strips the residual Montgomery factor after a round trip (Eq. 10.4).
//
// Latency is 5 clocks in every mode, so results never reorder when the host
// switches mode mid-stream. Throughput is one operation per clock.
//
// Timing, in cycles relative to in_valid:
//   0  capture operands; form a+b and b-a
//   1  issue fqmul and Barrett -- exactly one operation each, so neither unit
//      is ever oversubscribed and no arbitration is needed
//   3  Barrett result, latched (Barrett is latency 2, fqmul latency 3)
//   4  fqmul result; final add/sub and output mux
//   5  a_out / b_out valid

`default_nettype none

module bfu_core (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire        [2:0]  mode,
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    input  wire signed [15:0] zeta,
    output reg  signed [15:0] a_out,
    output reg  signed [15:0] b_out,
    output reg                out_valid
);

    localparam [2:0] MODE_CT      = 3'd0,
                     MODE_GS      = 3'd1,
                     MODE_FQMUL   = 3'd2,
                     MODE_BARRETT = 3'd3,
                     MODE_ADD     = 3'd4;

    // ---- cycle 0: capture, and form the two combinations the kernels need --
    // GS multiplies (b - a) and Barrett-reduces (a + b), so both are formed
    // here rather than in front of the arithmetic units, which keeps these
    // adders out of the multiplier's first pipeline stage.
    wire signed [15:0] pre_sum     = a + b;
    wire signed [15:0] pre_diff_ba = b - a;

    reg signed [15:0] r_a, r_b, r_zeta, r_sum, r_diff_ba;
    reg        [2:0]  r_mode;
    reg               p0;

    always @(posedge clk) begin
        if (rst) begin
            r_a <= 16'sd0; r_b <= 16'sd0; r_zeta <= 16'sd0;
            r_sum <= 16'sd0; r_diff_ba <= 16'sd0; r_mode <= 3'd0; p0 <= 1'b0;
        end else begin
            r_a       <= a;
            r_b       <= b;
            r_zeta    <= zeta;
            r_sum     <= pre_sum;
            r_diff_ba <= pre_diff_ba;
            r_mode    <= mode;
            p0        <= in_valid;
        end
    end

    // ---- the shared Montgomery multiply ----------------------------------
    wire signed [15:0] fq_x = (r_mode == MODE_FQMUL) ? r_a : r_zeta;
    wire signed [15:0] fq_y = (r_mode == MODE_GS)    ? r_diff_ba : r_b;

    wire signed [15:0] fq_c;
    wire               fq_valid;

    fqmul u_fqmul (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (p0),
        .a         (fq_x),
        .b         (fq_y),
        .c         (fq_c),
        .out_valid (fq_valid)
    );

    // ---- the shared Barrett reducer --------------------------------------
    // Exactly one reduction per operation: (a+b) for GS, a for MODE_BARRETT.
    // Reducing both a and b would need two inputs per operation from a unit
    // that takes one per clock, which collides as soon as operations are
    // issued back to back.
    wire signed [15:0] br_in = (r_mode == MODE_BARRETT) ? r_a : r_sum;

    wire signed [15:0] br_c;
    wire               br_valid;

    barrett_reduce u_barrett (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (p0),
        .a         (br_in),
        .c         (br_c),
        .out_valid (br_valid)
    );

    // ---- align the two units: fqmul is latency 3, Barrett latency 2 -------
    // Barrett slot 0 lands a cycle before the fqmul result, so it is held.
    reg p0_d1, p0_d2, p0_d3;
    always @(posedge clk) begin
        if (rst) begin
            p0_d1 <= 1'b0; p0_d2 <= 1'b0; p0_d3 <= 1'b0;
        end else begin
            p0_d1 <= p0;   p0_d2 <= p0_d1; p0_d3 <= p0_d2;
        end
    end

    reg signed [15:0] br0;                 // Barrett result, held one cycle
    always @(posedge clk) begin
        if (rst)        br0 <= 16'sd0;
        else if (p0_d2) br0 <= br_c;       // Barrett result emerges at cycle 3
    end

    // ---- bypass a, b and mode to the output stage ------------------------
    reg signed [15:0] a_b1, a_b2, a_b3;
    reg signed [15:0] b_b1, b_b2, b_b3;
    reg        [2:0]  m_b1, m_b2, m_b3;

    always @(posedge clk) begin
        if (rst) begin
            a_b1 <= 16'sd0; a_b2 <= 16'sd0; a_b3 <= 16'sd0;
            b_b1 <= 16'sd0; b_b2 <= 16'sd0; b_b3 <= 16'sd0;
            m_b1 <= 3'd0;   m_b2 <= 3'd0;   m_b3 <= 3'd0;
        end else begin
            a_b1 <= r_a;    a_b2 <= a_b1;   a_b3 <= a_b2;
            b_b1 <= r_b;    b_b2 <= b_b1;   b_b3 <= b_b2;
            m_b1 <= r_mode; m_b2 <= m_b1;   m_b3 <= m_b2;
        end
    end

    // ---- cycle 4: the output mux -----------------------------------------
    // fq_c is live this cycle; br0 was held from cycle 3.
    wire signed [15:0] ct_hi = a_b3 + fq_c;    // a + t
    wire signed [15:0] ct_lo = a_b3 - fq_c;    // a - t
    wire signed [15:0] pl_hi = a_b3 + b_b3;    // a + b
    wire signed [15:0] pl_lo = a_b3 - b_b3;    // a - b

    reg signed [15:0] nxt_a, nxt_b;
    always @(*) begin
        case (m_b3)
            MODE_CT:      begin nxt_a = ct_hi; nxt_b = ct_lo; end
            MODE_GS:      begin nxt_a = br0;   nxt_b = fq_c;  end
            MODE_FQMUL:   begin nxt_a = fq_c;  nxt_b = fq_c;  end
            MODE_BARRETT: begin nxt_a = br0;   nxt_b = br0;   end
            MODE_ADD:     begin nxt_a = pl_hi; nxt_b = pl_lo; end
            default:      begin nxt_a = pl_hi; nxt_b = pl_lo; end
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            a_out     <= 16'sd0;
            b_out     <= 16'sd0;
            out_valid <= 1'b0;
        end else begin
            a_out     <= nxt_a;
            b_out     <= nxt_b;
            out_valid <= p0_d3;
        end
    end

    // The datapath keys off the p0 delay chain rather than the units' own
    // valid outputs; sink the unused ones so the linter knows that is intended.
    wire _unused = &{1'b0, fq_valid, br_valid, p0_d1,
                     a_b1, a_b2, b_b1, b_b2, m_b1, m_b2, 1'b0};

endmodule

`default_nettype wire
