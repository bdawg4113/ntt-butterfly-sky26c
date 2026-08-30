// butterfly.v -- pipelined Cooley-Tukey butterfly for the ML-KEM forward NTT
//
//   t     = zeta * b mod q      (twiddle multiply, 3 pipeline stages)
//   a_out = a + t     mod q     (upper output -> f[j])
//   b_out = a - t     mod q     (lower output -> f[j+len])
//
// Latency 4 clocks, throughput 1 butterfly/clock. Stage breakdown:
//
//   cycle 0 : a,b,zeta presented with in_valid; mod_mult stage 1 latches a*b
//   cycle 1 : mod_mult stage 2 (quotient estimate)
//   cycle 2 : mod_mult stage 3 (reduce)   -> t valid at start of cycle 3
//   cycle 3 : mod_add / mod_sub combinational, result latched
//   cycle 4 : a_out/b_out valid, out_valid high
//
// 'a' bypasses the multiplier, so it is delayed through a 3-deep shift
// register to line up with t in cycle 3. 'b' and 'zeta' are consumed by the
// multiplier in cycle 0 and are not needed again.

`default_nettype none

module butterfly (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high
    input  wire        in_valid,   // a/b/zeta are a live operand set this cycle
    input  wire [11:0] a,          // f[j]
    input  wire [11:0] b,          // f[j+len]
    input  wire [11:0] zeta,       // twiddle factor
    output reg  [11:0] a_out,      // f[j]      after butterfly
    output reg  [11:0] b_out,      // f[j+len]  after butterfly
    output reg         out_valid   // a_out/b_out live (in_valid delayed 4)
);

    // ---- twiddle multiply: t = zeta * b mod q, 3 stages ------------------
    wire [11:0] t;
    wire        t_valid;

    mod_mult u_mult (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (in_valid),
        .a         (zeta),
        .b         (b),
        .c         (t),
        .out_valid (t_valid)
    );

    // ---- delay 'a' by the multiplier latency (3) so it meets t -----------
    reg [11:0] a_d1, a_d2, a_d3;
    always @(posedge clk) begin
        if (rst) begin
            a_d1 <= 12'd0;
            a_d2 <= 12'd0;
            a_d3 <= 12'd0;
        end else begin
            a_d1 <= a;
            a_d2 <= a_d1;
            a_d3 <= a_d2;
        end
    end

    // ---- final stage: the modular add and subtract -----------------------
    wire [11:0] sum, diff;

    mod_add u_add (.a (a_d3), .b (t), .c (sum));
    mod_sub u_sub (.a (a_d3), .b (t), .c (diff));

    always @(posedge clk) begin
        if (rst) begin
            a_out     <= 12'd0;
            b_out     <= 12'd0;
            out_valid <= 1'b0;
        end else begin
            a_out     <= sum;
            b_out     <= diff;
            out_valid <= t_valid;
        end
    end

endmodule

`default_nettype wire
