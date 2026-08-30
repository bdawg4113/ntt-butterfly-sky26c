/*
 * tt_um_ntt.v -- Tiny Tapeout wrapper for the ML-KEM NTT butterfly co-processor.
 *
 * Pin map:
 *   ui_in [7:0]  operand byte bus   (4-byte frame: a, b, twiddle index k)
 *   uio_in[0]    in_valid strobe
 *   uo_out[7:0]  result byte bus    (3-byte frame: a_out, b_out)
 *   uio_out[1]   out_valid strobe
 *   uio_out[2]   busy
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_ntt (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    wire       in_valid  = uio_in[0];
    wire [7:0] out_byte;
    wire       out_valid;
    wire       busy;

    bfu_stream u_bfu (
        .clk       (clk),
        .rst       (~rst_n),    // the core uses active-high reset, TT supplies active-low
        .in_byte   (ui_in),
        .in_valid  (in_valid),
        .out_byte  (out_byte),
        .out_valid (out_valid),
        .busy      (busy)
    );

    assign uo_out = out_byte;

    // uio[0] is the in_valid input; uio[1] and uio[2] are status outputs.
    assign uio_out = {5'b00000, busy, out_valid, 1'b0};
    assign uio_oe  = 8'b00000110;

    // Sink the inputs the design does not read: ena is tied high by the
    // harness and uio_in[7:1] are spare.
    wire _unused = &{ena, uio_in[7:1], 1'b0};

endmodule

`default_nettype wire
