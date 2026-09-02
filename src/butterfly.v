// butterfly.v -- the datapath: six operations over one pipelined multiplier
// and one Barrett reducer.
//
// All values are signed 16-bit and centred; q = 3329, R = 2^16.
//
//  op  name     a_out              b_out              muls  used by
//  --  -------  -----------------  -----------------  ----  --------------------
//  0   CT       a + fqmul(z,b)     a - fqmul(z,b)       1   forward NTT
//  1   GS       barrett(a + b)     fqmul(z, b - a)      1   inverse NTT
//  2   FQMUL    fqmul(a, b)        same                 1   scaling, basemul
//  3   ZMUL     fqmul(z, a)        same                 1   basemul's twiddle
//  4   BARRETT  barrett(a)         same                 0   range control
//  5   ADD      a + b              a - b                0   poly add/subtract
//
// z is the twiddle, selected by INDEX -- the table is on chip, in Montgomery
// form, so fqmul(z, x) lands as zeta*x with no stray factor.
//
// ---------------------------------------------------------------------------
// Both reductions, and the division of labour between them
// ---------------------------------------------------------------------------
// Montgomery and Barrett are not alternatives here; each does the job the other
// is bad at, exactly as the textbook sets out.
//
// MONTGOMERY after every multiply, because a multiply is where the R
// bookkeeping is free: the twiddle carries a factor R, the product cancels it,
// and the reduction costs two constant multiplies that ride inside the
// multiplier's own pipeline.
//
// BARRETT after chains of additions, where no R factor is involved and the
// value simply needs to come back into range. Gentleman-Sande adds a and b
// every layer with no multiply on that path, so without a reducer the sum grows
// layer over layer until it overflows the 16-bit datapath. Barrett pulls it
// back to (-q/2, q/2] and introduces no Montgomery factor while doing it.
//
// The alternative -- reusing fqmul with the constant R mod q to do range
// reduction -- is arithmetically sound and was what an earlier revision did.
// It costs a second pass through the multiplier for every GS butterfly,
// doubling the inverse transform's multiply count. A dedicated Barrett unit
// buys that back: GS now needs one multiply, not two, and the add and the
// multiply happen in parallel rather than in sequence.
//
// ---------------------------------------------------------------------------
// Why the inverse transform is nearly free
// ---------------------------------------------------------------------------
// CT and GS are the same primitives in a different order: CT multiplies then
// adds and subtracts; GS subtracts, then adds and reduces. The only structural
// difference is that GS needs its subtract BEFORE the multiplier where CT needs
// one after. Everything expensive is shared -- the multiplier, its three
// pipeline stages, the ROM, the operand registers.
//
// ---------------------------------------------------------------------------
// Latency
// ---------------------------------------------------------------------------
// 3 clocks for the four ops that multiply, set entirely by fqmul. BARRETT and
// ADD use no multiplier at all and are combinational, so the caller must poll
// rather than assume a fixed latency. a, b and zeta must hold steady from
// in_valid until out_valid: the post-multiply adder and subtractor read them
// live rather than from a delay chain, which saves 32 flip-flops and costs
// nothing, because the caller holds them in its operand registers anyway.

`default_nettype none

module butterfly (
    input  wire               clk,
    input  wire               rst,
    input  wire        [2:0]  op,
    input  wire               in_valid,    // a, b, zeta are live this clock
    input  wire signed [15:0] a,           // must hold until out_valid
    input  wire signed [15:0] b,
    input  wire signed [15:0] zeta,        // Montgomery-domain, from the ROM
    output wire signed [15:0] a_out,
    output wire signed [15:0] b_out,
    output wire               out_valid    // 3 clocks; unused by BARRETT and ADD
);

    localparam [2:0] OP_CT      = 3'd0,
                     OP_GS      = 3'd1,
                     OP_FQMUL   = 3'd2,
                     OP_ZMUL    = 3'd3,
                     OP_BARRETT = 3'd4,
                     OP_ADD     = 3'd5;

    // ---- the two sums the datapath needs ----------------------------------
    // Plain 16-bit two's complement, no modular correction: inside the
    // transforms no intermediate reaches the wrap point, and where growth does
    // accumulate -- the GS path -- Barrett is what brings it back.
    wire signed [15:0] sum  = a + b;
    wire signed [15:0] diff = b - a;

    // ---- the multiplier ----------------------------------------------------
    // FQMUL is the only op that puts a on the first operand; every other
    // multiplying op wants the twiddle there.
    wire signed [15:0] mul_x = (op == OP_FQMUL) ? a : zeta;
    wire signed [15:0] mul_y = (op == OP_GS)    ? diff :
                               (op == OP_ZMUL)  ? a    : b;

    wire signed [15:0] t;

    fqmul u_fqmul (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (in_valid),
        .a         (mul_x),
        .b         (mul_y),
        .c         (t),
        .out_valid (out_valid)
    );

    // ---- the Barrett reducer ----------------------------------------------
    // Shared between GS, which reduces a + b, and the standalone BARRETT op,
    // which reduces a. One unit, two callers, one mux.
    wire signed [15:0] bar_in = (op == OP_GS) ? sum : a;
    wire signed [15:0] bar_out;

    barrett_reduce u_barrett (
        .a (bar_in),
        .c (bar_out)
    );

    // ---- output selection --------------------------------------------------
    wire mirrored = (op == OP_FQMUL) | (op == OP_ZMUL) | (op == OP_BARRETT);

    assign a_out = (op == OP_CT)      ? a + t   :
                   (op == OP_GS)      ? bar_out :
                   (op == OP_FQMUL)   ? t       :
                   (op == OP_ZMUL)    ? t       :
                   (op == OP_BARRETT) ? bar_out :
                                        sum;      // OP_ADD

    assign b_out = (op == OP_CT)  ? a - t :
                   (op == OP_ADD) ? a - b :
                   (op == OP_GS)  ? t     :
                                    a_out;        // FQMUL, ZMUL, BARRETT mirror

    // mirrored is documentation for the assignment above, not a separate signal
    wire _unused = &{1'b0, mirrored, 1'b0};

endmodule

`default_nettype wire
