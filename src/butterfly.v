// butterfly.v -- the datapath: five operations over one pipelined multiplier.
//
// All values are 12-bit unsigned field elements in [0, q), q = 3329.
//
//  op  name   a_out              b_out            muls  used by
//  --  -----  -----------------  ---------------  ----  ----------------------
//  0   CT     (a + z*b) mod q    (a - z*b) mod q    1   forward NTT
//  1   GS     (a + b)   mod q    z*(b - a) mod q    1   inverse NTT
//  2   MUL    (a * b)   mod q    same               1   basemul, the 1/n scale
//  3   ZMUL   (z * a)   mod q    same               1   basemul's twiddle multiply
//  4   ADD    (a + b)   mod q    (a - b)   mod q    0   polynomial add/subtract
//
// z is the twiddle, which the caller selects by INDEX -- the table is on chip.
//
// ---------------------------------------------------------------------------
// Why the inverse transform is nearly free
// ---------------------------------------------------------------------------
// CT and GS are the same three primitives in a different order: CT multiplies
// and then adds and subtracts; GS subtracts, then adds and multiplies. Written
// out, the only structural difference is that GS needs a subtract BEFORE the
// multiplier where CT needs one after.
//
//     CT:   b ---------------\                a --> [+] --> a_out
//         zeta -> [ * ] --> t                 a --> [-] --> b_out
//
//     GS:   b,a -> [-] --> d                  a,b -> [+] --> a_out
//         zeta -> [ * ] --> t = b_out
//
// So the inverse transform costs exactly one extra mod_sub -- a 13-bit adder
// and a mux -- plus a few 12-bit operand multiplexers. Everything expensive is
// shared: the multiplier and its three pipeline stages, the twiddle ROM, the
// operand registers. Adding the INTT does not add a second datapath; it rewires
// the one that is already there.
//
// MUL and ZMUL are the same one multiply pointed at different operands, and
// they exist for basemul: the incomplete NTT leaves degree-1 polynomials, so a
// pointwise product is a multiplication modulo x^2 - zeta, which is four plain
// products, one twiddle multiply and two adds. ZMUL is what keeps the twiddle
// table on chip for that last part -- without it the host would have to hold
// the table after all, purely to supply basemul's +/-zetas[64+i].
//
// ADD takes no multiply at all, so its result is live in the same cycle. The
// caller must therefore not assume a fixed latency; poll the valid line.
//
// ---------------------------------------------------------------------------
// Latency
// ---------------------------------------------------------------------------
// 3 clocks for every op except ADD, set entirely by mod_mult. a, b and zeta
// must hold steady from in_valid until out_valid: the post-multiply adder and
// subtractor read them live rather than from a delay chain, which saves 24
// flip-flops and costs nothing, because the caller holds them in its operand
// registers for the whole operation anyway.

`default_nettype none

module butterfly (
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  op,
    input  wire        in_valid,    // a, b, zeta are live this clock
    input  wire [11:0] a,           // must hold until out_valid
    input  wire [11:0] b,
    input  wire [11:0] zeta,        // already sign-adjusted by the caller
    output wire [11:0] a_out,
    output wire [11:0] b_out,
    output wire        out_valid    // 3 clocks after in_valid; ADD does not use it
);

    localparam [2:0] OP_CT   = 3'd0,
                     OP_GS   = 3'd1,
                     OP_MUL  = 3'd2,
                     OP_ZMUL = 3'd3,
                     OP_ADD  = 3'd4;

    // ---- before the multiplier -------------------------------------------
    // GS wants z*(b - a). This is the one block the forward transform does not
    // use, and it is the whole hardware cost of supporting the inverse.
    wire [11:0] d;

    mod_sub u_presub (
        .a (b),
        .b (a),
        .c (d)
    );

    wire [11:0] mul_x = (op == OP_MUL)  ? a : zeta;
    wire [11:0] mul_y = (op == OP_GS)   ? d :
                        (op == OP_ZMUL) ? a : b;

    wire [11:0] t;

    mod_mult u_mult (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (in_valid),
        .a         (mul_x),
        .b         (mul_y),
        .c         (t),
        .out_valid (out_valid)
    );

    // ---- after the multiplier --------------------------------------------
    // One adder and one subtractor serve every op that needs them: the adder
    // takes the product for CT and the raw operand for GS and ADD, and the
    // subtractor the other way round.
    wire [11:0] sum, dif;

    mod_add u_add (
        .a (a),
        .b ((op == OP_CT)  ? t : b),
        .c (sum)
    );

    mod_sub u_sub (
        .a (a),
        .b ((op == OP_ADD) ? b : t),
        .c (dif)
    );

    wire mirrored = (op == OP_MUL) | (op == OP_ZMUL);

    assign a_out = mirrored ? t : sum;
    assign b_out = ((op == OP_CT) | (op == OP_ADD)) ? dif : t;

endmodule

`default_nettype wire
