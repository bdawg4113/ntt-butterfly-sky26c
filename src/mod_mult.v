// mod_mult.v -- c = (a * b) mod q, q = 3329, by Barrett reduction.
//
// Barrett replaces the division in "mod q" with a multiply by a precomputed
// reciprocal and a shift. The textbook form is
//
//     T   = a * b                       < q^2 = 11,082,241 < 2^24
//     quo = (T * MU) >> 24              MU = floor(2^24 / q) = 5039
//     r   = T - quo*q                   in [0, 2q)
//     c   = (r >= q) ? r - q : r        one conditional subtract
//
// and that is what this block used to do. It is not the cheapest form.
//
// ---------------------------------------------------------------------------
// Estimating the quotient from the top of T only
// ---------------------------------------------------------------------------
// The quotient estimate does not need all 24 bits of T. Shifting T right first
// and multiplying only its top gives
//
//     quo = ((T >> 11) * MU) >> 13      same MU = 5039
//
// which turns a 24x13 constant multiply into a 13x13 one -- roughly half the
// gates in the most expensive stage of the block. Discarding the low 11 bits
// makes the estimate coarser, so the remainder lands in [0, 6936) rather than
// [0, 2q), and finishing it takes two conditional subtracts instead of one.
// That is a good trade: a 13-bit compare-and-subtract is a few dozen cells,
// half a constant multiplier is several hundred.
//
// The bound is not an argument, it is a measurement: over every one of the
// 11,082,241 reachable products the largest remainder before the subtracts is
// 6935. Two things follow. Two conditional subtracts always suffice, since
// 6935 - 2q = 277. And 6935 < 2^13, so the whole finishing datapath stays 13
// bits wide -- shifting one bit further right (s = 12) would have pushed the
// worst case to 8975 and cost a 14th bit everywhere downstream.
//
// Only the low 13 bits of T and of quo*q are ever needed. The two agree above
// bit 12 by construction -- their difference is smaller than 2^13 -- so the
// subtraction cannot borrow out of that field and a 13-bit subtract is exact.
// Both products are therefore declared 13 bits wide, so the synthesiser builds
// only the part of each multiplier that is read. There is no 24-bit subtractor
// and no 26-bit product anywhere in this block.
//
// ---------------------------------------------------------------------------
// Why this is pipelined
// ---------------------------------------------------------------------------
// Written combinationally, the expression chains THREE multipliers back to
// back: a*b, then *MU, then *q. A 12x12 array is roughly 30-40 gate levels in
// sky130, so the chain runs to something like 120 levels, or 12-18 ns at
// 0.1-0.15 ns per level. Against a 20 ns period that is a margin of 1.1-1.6x,
// which is no margin at all once place-and-route adds wire delay -- exactly the
// path that closes in synthesis and fails at the slow corner.
//
// Three register stages put one multiply in each:
//
//     stage 1   t_hi <= (a*b) >> 11,  t_lo <= (a*b)[12:0]     one 12x12
//     stage 2   quo  <= (t_hi * MU) >> 13                     one 13x13
//     stage 3   c    <= finish(t_lo - (quo*q)[12:0])          one 13x12 (low)
//
// Latency is exactly 3 clocks, always, and in_valid/out_valid carry an
// operation through so the caller never counts clocks. The latency is free
// here: the byte-serial pin interface cannot deliver operands anywhere near
// one per clock, so a shorter pipeline would only idle.

`default_nettype none

module mod_mult (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high
    input  wire        in_valid,     // a, b are live this clock
    input  wire [11:0] a,            // field element, < q
    input  wire [11:0] b,            // field element, < q
    output wire [11:0] c,            // (a*b) mod q, < q
    output wire        out_valid     // c is live this clock, 3 clocks after in_valid
);

    localparam [12:0] Q  = 13'd3329;
    localparam [12:0] MU = 13'd5039;    // floor(2^24 / q)

    // ---- stage 1: the product ---------------------------------------------
    // The two halves the reduction needs are split here and the rest of the
    // 24-bit product is never registered: bits 23..13 take part in neither the
    // quotient estimate nor the subtraction.
    reg [12:0] s1_hi;      // (a*b) >> 11, the quotient estimate's input
    reg [12:0] s1_lo;      // (a*b)[12:0], the subtraction's input
    reg        s1_v;

    wire [23:0] prod = a * b;          // 24 bits: (q-1)^2 needs exactly 24

    always @(posedge clk) begin
        if (rst) begin
            s1_hi <= 13'd0;
            s1_lo <= 13'd0;
            s1_v  <= 1'b0;
        end else begin
            s1_hi <= prod[23:11];
            s1_lo <= prod[12:0];
            s1_v  <= in_valid;
        end
    end

    // ---- stage 2: the Barrett quotient estimate ---------------------------
    reg [12:0] s2_quo;
    reg [12:0] s2_lo;
    reg        s2_v;

    wire [25:0] t_mu = s1_hi * MU;

    always @(posedge clk) begin
        if (rst) begin
            s2_quo <= 13'd0;
            s2_lo  <= 13'd0;
            s2_v   <= 1'b0;
        end else begin
            s2_quo <= t_mu[25:13];
            s2_lo  <= s1_lo;
            s2_v   <= s1_v;
        end
    end

    // ---- stage 3: subtract, then finish -----------------------------------
    // r is in [0, 6936), so two conditional subtracts bring it into [0, q).
    // The 13-bit width of quo_q is deliberate: only the low half of quo*q is
    // ever read, and declaring it narrow is what stops the synthesiser
    // building the other half.
    reg [11:0] s3_c;
    reg        s3_v;

    wire [12:0] quo_q = s2_quo * Q;
    wire [12:0] r0    = s2_lo - quo_q;         // in [0, 6936)
    wire [12:0] r1    = (r0 >= Q)     ? r0 - Q : r0;
    wire [12:0] r2    = (r1 >= Q)     ? r1 - Q : r1;

    always @(posedge clk) begin
        if (rst) begin
            s3_c <= 12'd0;
            s3_v <= 1'b0;
        end else begin
            s3_c <= r2[11:0];
            s3_v <= s2_v;
        end
    end

    assign c         = s3_c;
    assign out_valid = s3_v;

endmodule

`default_nettype wire
