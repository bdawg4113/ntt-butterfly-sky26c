// ntt_top.v -- the engine: byte-serial front end, twiddle ROM, datapath.
//
//                        +--------------+
//        pins  <-------> |   ntt_io     |  operand registers, launch, unload
//                        +--+--------+--+
//                       k |          | a, b, zeta, op
//                  +------v-----+  +-v------------+
//                  | twiddle_rom|  |  butterfly   |
//                  |  128 x 12  |->| CT GS MUL    |
//                  +------------+ z| ZMUL ADD     |
//                                  +------+-------+
//                                         |
//                                  +------v-------+
//                                  |  mod_mult    |  3-stage Barrett
//                                  +--------------+
//
// ---------------------------------------------------------------------------
// What is on chip and what is not
// ---------------------------------------------------------------------------
// The twiddle table is here. The polynomial is not, and that is not a matter
// of effort: 256 coefficients of 12 bits is 3,072 flip-flops, which at roughly
// 26 um2 for an enable flop is about 80,800 um2 -- 222% of a 1x2 tile's
// 36,347 um2 of die, before a single read multiplexer, write decoder or gate
// of arithmetic. A build that held the array measured 24,706 cells with
// coeff_mem accounting for 21,248 of them, 86% of the design, and needed 8x2.
//
// The twiddle ROM is the opposite trade. It is 467 cells, it removes a
// 128-entry table from the host's memory map, and it turns the per-block
// twiddle write into a single index byte. Constants belong on chip; state that
// scales with the problem size does not, when the tile is this size.
//
// So the host holds the 256 coefficients and walks the FIPS 203 address
// pattern; the chip holds the constants and does every piece of modular
// arithmetic the transform needs. Both transforms, and basemul, are covered by
// the five ops in butterfly.v.

`default_nettype none

module ntt_top (
    input  wire       clk,
    input  wire       rst,          // synchronous, active high

    input  wire [7:0] in_byte,
    input  wire [2:0] waddr,
    input  wire       we,
    input  wire       start,
    output wire [7:0] out_byte,
    output wire       out_valid,
    output wire       busy
);

    wire [6:0]  k_idx;
    wire [11:0] rom_zeta;

    wire [2:0]  op;
    wire        issue;
    wire [11:0] a, b, zeta;
    wire [11:0] a_out, b_out;
    wire        mul_done;

    ntt_io u_io (
        .clk       (clk),
        .rst       (rst),
        .in_byte   (in_byte),
        .waddr     (waddr),
        .we        (we),
        .start     (start),
        .out_byte  (out_byte),
        .out_valid (out_valid),
        .busy      (busy),
        .k_idx     (k_idx),
        .rom_zeta  (rom_zeta),
        .op        (op),
        .issue     (issue),
        .a         (a),
        .b         (b),
        .zeta      (zeta),
        .a_out     (a_out),
        .b_out     (b_out),
        .mul_done  (mul_done)
    );

    twiddle_rom u_rom (
        .k    (k_idx),
        .zeta (rom_zeta)
    );

    butterfly u_butterfly (
        .clk       (clk),
        .rst       (rst),
        .op        (op),
        .in_valid  (issue),
        .a         (a),
        .b         (b),
        .zeta      (zeta),
        .a_out     (a_out),
        .b_out     (b_out),
        .out_valid (mul_done)
    );

endmodule

`default_nettype wire
