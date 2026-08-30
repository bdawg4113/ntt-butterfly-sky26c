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

// coeff_mem.v -- the 256 x 12 polynomial coefficient array
//
// Two combinational read ports (f[j] and f[j+len] for the butterfly) and two
// write ports (the butterfly's a_out/b_out going back to the same addresses,
// delayed by the pipeline latency).
//
//                     +------------------+
//   r_addr_a (FSM) -->|                  |--> dout_a --> butterfly.a
//   r_addr_b (FSM) -->|   coeff memory   |--> dout_b --> butterfly.b
//                     |     256 x 12     |
//   butterfly.a_out ->|                  |
//   butterfly.b_out ->|                  |
//   we (butterfly    -|                  |
//       out_valid)    +------------------+
//
// Reads are combinational so the memory read and the multiplier's first
// pipeline stage both fit in the issue cycle. Writes are clocked.
//
// The preload below is simulation-only. On real silicon this array comes up
// undefined and has to be filled through the chip's pins; $readmemh is guarded
// so the synthesiser never sees a file reference it cannot resolve.

`default_nettype none

module coeff_mem (
    input  wire        clk,
    input  wire        rst,
    input  wire        we,          // write enable (butterfly out_valid)
    input  wire [7:0]  r_addr_a,    // = j
    input  wire [7:0]  r_addr_b,    // = j + len
    input  wire [7:0]  w_addr_a,    // write address for butterfly a_out
    input  wire [7:0]  w_addr_b,    // write address for butterfly b_out
    input  wire [11:0] din_a,       // butterfly a_out
    input  wire [11:0] din_b,       // butterfly b_out
    output wire [11:0] dout_a,      // -> butterfly.a
    output wire [11:0] dout_b       // -> butterfly.b
);

    reg [11:0] mem [0:255];

`ifdef NTT_PRELOAD_COEFFS
    // Simulation only: load the vector the cocotb tests check against.
    // Override the path with -DNTT_COEFF_FILE='"..."' if you relocate the file.
  `ifndef NTT_COEFF_FILE
    `define NTT_COEFF_FILE "init_coeffs.hex"
  `endif
    initial begin
        $readmemh(`NTT_COEFF_FILE, mem);
    end
`endif

    // combinational reads: data available in the same cycle as the address
    assign dout_a = mem[r_addr_a];
    assign dout_b = mem[r_addr_b];

    // clocked writes
    always @(posedge clk) begin
        if (we && !rst) begin
            mem[w_addr_a] <= din_a;
            mem[w_addr_b] <= din_b;
        end
    end

endmodule

`default_nettype wire
