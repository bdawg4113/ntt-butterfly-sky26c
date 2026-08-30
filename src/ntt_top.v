// -----------------------------------------------------------------------------
// REFERENCE MODEL -- NOT part of the hardened Tiny Tapeout design.
//
// This is the self-contained NTT sequencer with an on-chip coefficient array.
// It is kept because test/Makefile_top verifies it against the Python golden
// model, which is what proves the butterfly and twiddle ROM implement FIPS 203
// Algorithm 9 correctly. It is deliberately absent from info.yaml's
// source_files: as flip-flops the 256x12 array synthesises to 6144 registers
// (two combinational read ports force Yosys to duplicate the storage), which
// exceeds even the largest 8x2 tile. The taped-out design streams coefficients
// over the pins instead -- see src/bfu_stream.v.
// -----------------------------------------------------------------------------

// ntt_top.v -- the NTT engine: sequencer + memory + twiddle ROM + butterfly
//
// Runs the full 7-stage ML-KEM forward NTT over the 256 coefficients held in
// coeff_mem. Assert start for one clock; done goes high when the transform is
// finished and stays high until the next start.
//
// The datapath is pipelined and issues one butterfly per clock:
//
//   control_fsm --(r_addr_a/b, k_idx, issue)--> coeff_mem + twiddle_rom
//                                                      |
//                                                  butterfly (latency 4)
//                                                      |
//   control_fsm --(w_addr_a/b delayed by 4)-----> coeff_mem write port
//                                                 strobed by out_valid

`default_nettype none

module ntt_top (
    input  wire clk,
    input  wire rst,     // synchronous, active high
    input  wire start,
    output wire done
);

    // FSM -> memory
    wire [7:0]  r_addr_a, r_addr_b;
    wire [7:0]  w_addr_a, w_addr_b;
    wire        issue;

    // FSM -> ROM
    wire [6:0]  k_idx;

    // memory -> butterfly
    wire [11:0] mem_dout_a, mem_dout_b;

    // ROM -> butterfly
    wire [11:0] rom_zeta;

    // butterfly -> memory
    wire [11:0] bf_a_out, bf_b_out;
    wire        bf_valid;

    // 1. address sequencer
    control_fsm u_fsm (
        .clk      (clk),
        .rst      (rst),
        .start    (start),
        .r_addr_a (r_addr_a),
        .r_addr_b (r_addr_b),
        .k_idx    (k_idx),
        .issue    (issue),
        .w_addr_a (w_addr_a),
        .w_addr_b (w_addr_b),
        .done     (done)
    );

    // 2. coefficient memory -- written when a butterfly result comes out
    coeff_mem u_mem (
        .clk      (clk),
        .rst      (rst),
        .we       (bf_valid),
        .r_addr_a (r_addr_a),
        .r_addr_b (r_addr_b),
        .w_addr_a (w_addr_a),
        .w_addr_b (w_addr_b),
        .din_a    (bf_a_out),
        .din_b    (bf_b_out),
        .dout_a   (mem_dout_a),
        .dout_b   (mem_dout_b)
    );

    // 3. twiddle factor ROM
    twiddle_rom u_rom (
        .k    (k_idx),
        .zeta (rom_zeta)
    );

    // 4. pipelined butterfly datapath
    butterfly u_butterfly (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (issue),
        .a         (mem_dout_a),
        .b         (mem_dout_b),
        .zeta      (rom_zeta),
        .a_out     (bf_a_out),
        .b_out     (bf_b_out),
        .out_valid (bf_valid)
    );

endmodule

`default_nettype wire
