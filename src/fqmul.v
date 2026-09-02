// fqmul.v -- the workhorse multiply: fqmul(a,b) = a*b*R^-1 mod q.
//
// One 16x16 signed product into one Montgomery reduction. This is where the
// chip's Montgomery half lives; Barrett is a separate unit next door, and
// butterfly.v explains why both are here.
//
// ---------------------------------------------------------------------------
// The Montgomery reduction, Theorem 6.1
// ---------------------------------------------------------------------------
//     m = (a mod^+- R) * QINV mod^+- R
//     t = (a - m*q) / R
//
// with R = 2^16 and QINV = q^-1 mod R. For |a| < qR/2 the theorem gives: t is
// an integer, t = a*R^-1 (mod q), and |t| < q. Each claim is a piece of
// hardware, so each is worth reading as one.
//
// t IS AN INTEGER. By construction m = a*q^-1 (mod R), so m*q = a (mod R), so R
// divides a - m*q exactly. That is the whole trick: m is chosen precisely to
// cancel the low 16 bits, which makes the shift exact. In hardware the division
// by R is a wire, not a divider -- and better, since those low 16 bits are
// known to be zero they never have to be computed, so the subtraction collapses
// to a 16-bit subtract of the two top halves. There is no 32-bit subtractor in
// this module.
//
// t = a*R^-1 (mod q). Modulo q the m*q term vanishes, so t*R = a.
//
// |t| < q. With |m| <= R/2 and |a| < qR/2,
//     |t| = |a - m*q|/R <= (|a| + |m|q)/R < (qR/2 + qR/2)/R = q.
// That bound is what lets c be declared signed [15:0] with certainty it never
// overflows.
//
// THE SPURIOUS FACTOR. Montgomery does not return a mod q; it returns
// a*R^-1 mod q. Key Idea 6.1 resolves this by keeping everything in the
// Montgomery domain: the zetas table is stored pre-multiplied by R, so
// fqmul(zeta*R, x) = zeta*x arrives with no stray factor. twiddle_rom.v holds
// exactly that table. It is also why a bare montgomery_reduce is available to
// the host as fqmul(x, 1), which is what strips the residual R after a round
// trip.
//
// The precondition is |a*b| < q*R/2 = 3329 * 2^15. Both operands are field
// elements the transforms keep below q in magnitude, so |a*b| < q^2 = 1.1e7,
// far inside the 5.5e7 the bound allows.
//
// ---------------------------------------------------------------------------
// Why this is pipelined
// ---------------------------------------------------------------------------
// Written combinationally the block chains three multipliers back to back: the
// 16x16 product, then *QINV, then *q. A 16x16 array is roughly 40 gate levels
// in sky130 and the two constant multiplies add more, so the chain runs to
// something like 120 levels -- 12 to 18 ns at 0.1-0.15 ns per level. Against a
// 20 ns period that is a margin of 1.1 to 1.6x, which is no margin at all once
// place-and-route adds wire delay. It is the classic path that closes in
// synthesis and fails at the slow corner.
//
// Three register stages put one multiply in each:
//
//     stage 1   p   <= a * b                       one 16x16
//     stage 2   m   <= (p mod^+- R) * QINV         one 16x16 constant
//               p_hi<= p[31:16]                    carried alongside
//     stage 3   c   <= p_hi - (m*q)[31:16]         one 16x16 constant, then a
//                                                  16-bit subtract
//
// Splitting the Montgomery reduction across stages 2 and 3 matters as much as
// splitting off the product. Folding both constant multiplies into one cycle
// chains them, and with the product already cut away that chain would simply
// become the new critical path in its place.
//
// Latency is exactly 3 clocks, always, and in_valid/out_valid carry an
// operation through so the caller never counts clocks. The latency is free
// here: the byte-serial pin interface cannot deliver operands anywhere near one
// per clock, so a shorter pipeline would only idle.

`default_nettype none

module fqmul (
    input  wire               clk,
    input  wire               rst,        // synchronous, active high
    input  wire               in_valid,   // a, b are live this clock
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    output wire signed [15:0] c,          // a*b*R^-1 mod q, |c| < q
    output wire               out_valid   // 3 clocks after in_valid
);

    localparam signed [15:0] QINV = -16'sd3327;   // q^-1 mod 2^16
    localparam signed [15:0] Q    =  16'sd3329;

    // ---- stage 1: the product ---------------------------------------------
    reg signed [31:0] s1_p;
    reg               s1_v;

    wire signed [31:0] prod = a * b;

    always @(posedge clk) begin
        if (rst) begin
            s1_p <= 32'sd0;
            s1_v <= 1'b0;
        end else begin
            s1_p <= prod;
            s1_v <= in_valid;
        end
    end

    // ---- stage 2: the Montgomery factor -----------------------------------
    // m = (p mod^+- R) * QINV, kept to 16 bits. Only p's top half survives
    // alongside it: the low half has done its job once m is formed.
    reg signed [15:0] s2_m;
    reg signed [15:0] s2_phi;
    reg               s2_v;

    wire signed [15:0] p_lo   = s1_p[15:0];
    wire signed [31:0] m_full = p_lo * QINV;

    always @(posedge clk) begin
        if (rst) begin
            s2_m   <= 16'sd0;
            s2_phi <= 16'sd0;
            s2_v   <= 1'b0;
        end else begin
            s2_m   <= m_full[15:0];
            s2_phi <= s1_p[31:16];
            s2_v   <= s1_v;
        end
    end

    // ---- stage 3: subtract the top halves ----------------------------------
    // m*q agrees with p in the low 16 bits by construction, so the subtraction
    // cannot borrow out of them and a 16-bit subtract of the top halves is
    // exact. There is no 32-bit subtractor here.
    reg signed [15:0] s3_c;
    reg               s3_v;

    wire signed [31:0] mq = s2_m * Q;

    always @(posedge clk) begin
        if (rst) begin
            s3_c <= 16'sd0;
            s3_v <= 1'b0;
        end else begin
            s3_c <= s2_phi - mq[31:16];
            s3_v <= s2_v;
        end
    end

    assign c         = s3_c;
    assign out_valid = s3_v;

    // the low halves cancel by construction and are never read
    wire _unused = &{1'b0, m_full[31:16], mq[15:0], 1'b0};

endmodule

`default_nettype wire
