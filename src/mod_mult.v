// mod_mult.v -- 3-stage pipelined Barrett modular multiplier, q = 3329
//
//   c = (a * b) mod q      latency: 3 clocks      throughput: 1 result/clock
//
// Barrett reduction with k = 24, mu = floor(2^24 / q) = 5039:
//
//   T     = a * b                    (<= 3328^2 = 11075584, fits in 24 bits)
//   quo   = (T * mu) >> 24           (quotient estimate)
//   r     = T - quo*q                (exhaustively verified to stay < 2q)
//   c     = (r >= q) ? r - q : r     (so a single conditional subtract suffices)
//
// The bound on r was checked by brute force over all 11075585 possible values
// of T: max(r) = 4903 < 2q = 6658, so one conditional subtract is exact, and
// r < 8192 so evaluating the subtract in 13 bits never truncates a live bit.
//
// Why this is pipelined: the combinational version chained three multipliers
// back to back and measured 92 logic levels, which cannot close timing at the
// target clock. Each stage below now holds exactly one multiply.

`default_nettype none

module mod_mult (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high
    input  wire        in_valid,   // a/b are a live operand pair this cycle
    input  wire [11:0] a,          // field element, < q
    input  wire [11:0] b,          // field element, < q
    output wire [11:0] c,          // (a*b) mod q, < q
    output wire        out_valid   // c is live this cycle (in_valid delayed 3)
);

    localparam [12:0]  Q  = 13'd3329;
    localparam [12:0]  MU = 13'd5039;   // floor(2^24 / q)
    localparam integer K  = 24;

    // ---- stage 1: the 12x12 product -------------------------------------
    wire [23:0] s1_T_nxt = a * b;
    reg  [23:0] s1_T;
    reg         s1_valid;

    // ---- stage 2: quotient estimate, multiply by the constant MU ---------
    wire [36:0] s2_Tmu_nxt = s1_T * MU;
    reg  [12:0] s2_quo;
    reg  [12:0] s2_T_lo;                // low 13 bits of T, needed by stage 3
    reg         s2_valid;

    // ---- stage 3: multiply back by q, subtract, conditional subtract -----
    wire [25:0] s3_quo_q = s2_quo * Q;
    wire [12:0] s3_r     = s2_T_lo - s3_quo_q[12:0];
    wire        s3_ge    = (s3_r >= Q);
    // r <= 4903, so when r >= q the result r-q lies in [0, 1574] and the
    // 12-bit subtract is exact.
    wire [11:0] s3_res   = s3_ge ? (s3_r[11:0] - Q[11:0]) : s3_r[11:0];
    reg  [11:0] s3_c;
    reg         s3_valid;

    // Barrett needs the wide products, but only a slice of each one: the
    // quotient estimate is the top 13 bits of T*MU, and the remainder only
    // needs the bottom 13 bits of quo*q. Sink the rest so the linter knows
    // dropping them is deliberate.
    wire _unused = &{1'b0, s2_Tmu_nxt[23:0], s3_quo_q[25:13], 1'b0};

    always @(posedge clk) begin
        if (rst) begin
            s1_T     <= 24'd0;
            s1_valid <= 1'b0;
            s2_quo   <= 13'd0;
            s2_T_lo  <= 13'd0;
            s2_valid <= 1'b0;
            s3_c     <= 12'd0;
            s3_valid <= 1'b0;
        end else begin
            s1_T     <= s1_T_nxt;
            s1_valid <= in_valid;

            s2_quo   <= s2_Tmu_nxt[36:K];
            s2_T_lo  <= s1_T[12:0];
            s2_valid <= s1_valid;

            s3_c     <= s3_res;
            s3_valid <= s2_valid;
        end
    end

    assign c         = s3_c;
    assign out_valid = s3_valid;

endmodule

`default_nettype wire
