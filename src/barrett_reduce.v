// barrett_reduce.v -- signed Barrett reduction, section 6.3 and Theorem 6.2.
//
//     v = floor((2^k + q/2) / q)        k = 26, q = 3329  ->  v = 20159
//     t = floor((a*v + 2^25) / 2^26)
//     barrett(a) = a - t*q
//
// Theorem 6.2: for |a| < 2^15, barrett(a) = a (mod q) and the result lies in
// the centred range (-q/2, q/2].
//
// Barrett takes a different route from Montgomery: rather than cancelling low
// bits, it estimates the quotient a/q with a precomputed reciprocal and
// subtracts. Congruence is immediate -- an integer multiple of q was
// subtracted. The range claim is the part that needs the constants to be right:
// v/2^k approximates 1/q with error at most 1/2^(k+1), so t differs from
// round(a/q) by at most |a|/2^(k+1) + 1/2, which for |a| < 2^15 and k = 26 is
// below 1. So t IS round(a/q) exactly, and a - t*q is the centred remainder.
//
// Why 2^26. The proof needs |a|/2^(k+1) below 1/2, i.e. k >= 16. Taking k = 26
// buys a comfortable margin while keeping a*v inside 32 bits
// (2^15 * 20159 < 2^31), which is the widest product the hardware multiplier
// produces. The constant is chosen to make both bounds hold at once.
//
// ---------------------------------------------------------------------------
// Why this unit exists alongside Montgomery
// ---------------------------------------------------------------------------
// The two reductions are not alternatives; they do different jobs, and the
// textbook is explicit about the division of labour. Montgomery is used after
// every multiply, because a multiply is where the R bookkeeping is free -- the
// twiddle carries the R and the product cancels it. Barrett is used to tidy up
// after chains of additions, where there is no R factor involved and the value
// simply needs to come back into range.
//
// That is exactly what the inverse transform needs. Gentleman-Sande adds a and
// b every layer without any multiply on that path, so the sum grows layer over
// layer; Barrett pulls it back with no Montgomery factor introduced. Using
// fqmul(x, R mod q) for the same job would work arithmetically, but it would
// occupy the multiplier for a second pass -- which is precisely the cost this
// unit buys out.
//
// Combinational: one constant multiply, a rounding add, an arithmetic shift and
// one more constant multiply. Roughly 40 gate levels, comfortably inside a
// 20 ns period on its own, so it is not pipelined and the caller does not have
// to track a latency for it.

`default_nettype none

module barrett_reduce (
    input  wire signed [15:0] a,     // |a| < 2^15
    output wire signed [15:0] c      // a mod q, in (-q/2, q/2]
);

    localparam signed [15:0] Q = 16'sd3329;
    localparam signed [15:0] V = 16'sd20159;   // floor((2^26 + q/2)/q)

    // a*v + 2^25, then an arithmetic shift right by 26. The add is the
    // rounding term: it is what turns a floor into a round-to-nearest, and
    // without it t would be off by one for negative a.
    wire signed [31:0] av = a * V;             // |av| < 2^31
    wire signed [31:0] rounded = av + 32'sd33554432;   // + 2^25

    // t = round(a/q), which for |a| < 2^15 fits easily: |t| <= 10.
    //
    // An arithmetic shift, not a part-select. rounded[31:26] would be an
    // UNSIGNED slice: for negative a it would drop the sign and give a large
    // positive t, and the reduction would return nonsense for exactly half the
    // input range. >>> on a signed operand extends the sign instead.
    wire signed [15:0] t = rounded >>> 26;

    assign c = a - t * Q;

endmodule

`default_nettype wire
