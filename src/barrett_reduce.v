// barrett_reduce.v -- signed Barrett reduction, equation (10.2)
//
//   v = floor((2^26 + q/2) / q) = 20159
//   t = floor((v*a + 2^25) / 2^26)
//   c = a - t*q
//
// Maps any signed 16-bit value to a congruent value in a centred range around
// zero, without changing it mod q. The inverse transform uses it to stop the
// running sums growing out of range. One multiply, one rounding add, one
// shift, one multiply-subtract -- no division.
//
// Latency 2 clocks, one result per clock.

`default_nettype none

module barrett_reduce (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire signed [15:0] a,
    output wire signed [15:0] c,
    output wire               out_valid
);

    localparam signed [31:0] V     = 32'sd20159;    // floor((2^26 + q/2)/q)
    localparam signed [15:0] Q     = 16'sd3329;
    localparam integer       K     = 26;
    localparam signed [31:0] ROUND = 32'sd1 << (K - 1);

    // ---- stage 1: the rounded quotient estimate --------------------------
    // |v*a| <= 20159 * 32768 which is comfortably inside a signed 32-bit word.
    wire signed [31:0] scaled = (V * a) + ROUND;
    // |t| never exceeds about 10, so narrowing the shifted quotient is exact.
    wire signed [31:0] t_full = scaled >>> K;
    wire signed [15:0] t_nxt  = t_full[15:0];

    reg signed [15:0] s1_t;
    reg signed [15:0] s1_a;
    reg               s1_valid;

    always @(posedge clk) begin
        if (rst) begin
            s1_t     <= 16'sd0;
            s1_a     <= 16'sd0;
            s1_valid <= 1'b0;
        end else begin
            s1_t     <= t_nxt;
            s1_a     <= a;
            s1_valid <= in_valid;
        end
    end

    // ---- stage 2: subtract t*q -------------------------------------------
    // t*q can reach about 33290 and so does not fit a signed 16-bit word, but
    // the difference does (|c| <= q), so the subtract is done wide and only
    // the result is narrowed.
    wire signed [31:0] c_full = $signed({{16{s1_a[15]}}, s1_a}) - (s1_t * Q);

    reg signed [15:0] s2_c;
    reg               s2_valid;

    always @(posedge clk) begin
        if (rst) begin
            s2_c     <= 16'sd0;
            s2_valid <= 1'b0;
        end else begin
            s2_c     <= c_full[15:0];
            s2_valid <= s1_valid;
        end
    end

    assign c         = s2_c;
    assign out_valid = s2_valid;

    wire _unused = &{1'b0, c_full[31:16], t_full[31:16], 1'b0};

endmodule

`default_nettype wire
