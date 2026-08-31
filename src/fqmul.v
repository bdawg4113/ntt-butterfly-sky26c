// fqmul.v -- the workhorse multiply: one 16x16 product into one Montgomery
// reduction.
//
//   fqmul(a, b) = montgomery_reduce(a * b) = a * b * R^-1 mod q
//
// The twiddle table is stored pre-multiplied by R, so a butterfly multiply
// fqmul(zeta*R, x) = zeta*R*x*R^-1 = zeta*x lands with no stray Montgomery
// factor. Passing b = 1 turns this into a bare montgomery_reduce, which is how
// the host strips the residual R factor after a transform round trip.
//
// Latency 3 clocks (1 for the product, 2 for the reduction), one per clock.

`default_nettype none

module fqmul (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    output wire signed [15:0] c,          // a*b*R^-1 mod q, |c| < q
    output wire               out_valid
);

    // ---- stage 1: the 16x16 signed product -------------------------------
    wire signed [31:0] p_nxt = a * b;

    reg signed [31:0] p;
    reg               p_valid;

    always @(posedge clk) begin
        if (rst) begin
            p       <= 32'sd0;
            p_valid <= 1'b0;
        end else begin
            p       <= p_nxt;
            p_valid <= in_valid;
        end
    end

    // ---- stages 2-3: the Montgomery reduction ----------------------------
    montgomery_reduce u_mr (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (p_valid),
        .a         (p),
        .t         (c),
        .out_valid (out_valid)
    );

endmodule

`default_nettype wire
