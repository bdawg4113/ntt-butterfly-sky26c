// ntt_io.v -- byte-serial front end for the NTT/INTT datapath.
//
// Tiny Tapeout gives 8 data inputs, 8 data outputs and 8 bidirectional pins,
// which is narrower than the operand vector a butterfly needs. The host
// therefore assembles operands by addressed byte writes, pulses start, waits
// for busy to fall, and shifts the 24-bit result back out a byte at a time.
//
//   writing:  put a byte on in_byte, its register number on waddr, raise we
//
//     addr 0  a[7:0]        addr 4  k    = { 1'b0, twiddle index[6:0] }
//     addr 1  a[11:8]       addr 5  ctrl = { 4'b0, zneg, op[2:0] }
//     addr 2  b[7:0]        addr 6  reserved
//     addr 3  b[11:8]       addr 7  reserved
//
//   executing: a rising edge on start launches one operation. busy stays high
//              until the last result byte has been presented. The operand
//              registers must not be written while busy, since the datapath
//              reads them directly for the whole operation.
//
//   reading:  three bytes come back on out_byte, each qualified by out_valid,
//             low byte first, carrying { b_out[11:0], a_out[11:0] }:
//
//                 byte 0  a_out[7:0]
//                 byte 1  { b_out[3:0], a_out[11:8] }
//                 byte 2  b_out[11:4]
//
//             Two 12-bit results pack into three bytes exactly, so a butterfly
//             costs three read cycles rather than the four that two padded
//             16-bit values would.
//
// ---------------------------------------------------------------------------
// The twiddle is an index, not a value
// ---------------------------------------------------------------------------
// Register 4 holds k, and the 128-entry table is on chip in twiddle_rom. The
// host does not hold the twiddles: it walks the index the FIPS 203 transforms
// already define -- up from 1 for the forward NTT, down from 127 for the
// inverse -- and writes one byte per block rather than a 12-bit constant it had
// to look up itself.
//
// zneg selects q - z instead of z. basemul multiplies modulo x^2 - zeta with
// the signed pair +/-zetas[64+i], and in this unsigned representation the
// negative half is q - z, not a separate table entry. One 12-bit subtract is a
// great deal cheaper than 128 more ROM words.
//
// Registers persist between operations, so a host walking one NTT layer only
// rewrites the bytes that actually changed -- usually just the four operand
// bytes, since k and ctrl are constant across a whole block.

`default_nettype none

module ntt_io (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high

    input  wire [7:0]  in_byte,      // write data
    input  wire [2:0]  waddr,        // register select
    input  wire        we,           // write strobe
    input  wire        start,        // rising edge launches one operation

    output reg  [7:0]  out_byte,     // result byte
    output reg         out_valid,    // out_byte is live this clock
    output wire        busy,         // operation in flight, or result unloading

    // to the twiddle ROM
    output wire [6:0]  k_idx,
    input  wire [11:0] rom_zeta,

    // to the datapath
    output wire [2:0]  op,
    output wire        issue,
    output wire [11:0] a,
    output wire [11:0] b,
    output wire [11:0] zeta,
    input  wire [11:0] a_out,
    input  wire [11:0] b_out,
    input  wire        mul_done
);

    localparam [2:0] OP_ADD = 3'd4;
    localparam [11:0] Q = 12'd3329;

    // ---- operand registers -------------------------------------------------
    reg [11:0] a_reg, b_reg;
    reg [6:0]  k_reg;
    reg [2:0]  op_reg;
    reg        zneg_reg;

    always @(posedge clk) begin
        if (rst) begin
            a_reg    <= 12'd0;
            b_reg    <= 12'd0;
            k_reg    <= 7'd0;
            op_reg   <= 3'd0;
            zneg_reg <= 1'b0;
        end else if (we) begin
            case (waddr)
                3'd0: a_reg[7:0]  <= in_byte;
                3'd1: a_reg[11:8] <= in_byte[3:0];
                3'd2: b_reg[7:0]  <= in_byte;
                3'd3: b_reg[11:8] <= in_byte[3:0];
                3'd4: k_reg       <= in_byte[6:0];
                3'd5: begin
                    op_reg   <= in_byte[2:0];
                    zneg_reg <= in_byte[3];
                end
                default: ;          // addrs 6 and 7 reserved
            endcase
        end
    end

    assign a     = a_reg;
    assign b     = b_reg;
    assign op    = op_reg;
    assign k_idx = k_reg;

    // The negated twiddle, for basemul's -zetas[64+i]. z is always in [1, q),
    // so q - z needs no conditional correction.
    assign zeta = zneg_reg ? (Q - rom_zeta) : rom_zeta;

    // ---- launch on the rising edge of start --------------------------------
    // Gated on in_flight, which is a register, rather than on busy -- busy is
    // partly combinational and includes launch itself, so testing it here
    // would close a combinational loop through the enable of the very signal
    // being computed.
    reg start_d;
    reg in_flight;
    wire launch = start & ~start_d & ~in_flight;

    always @(posedge clk) begin
        if (rst) start_d <= 1'b0;
        else     start_d <= start;
    end

    // ADD needs no multiply, so its result is already live and the operation
    // finishes in the cycle it starts. Every other op waits for the multiplier.
    wire is_add = (op_reg == OP_ADD);

    assign issue = launch & ~is_add;

    // ---- waiting for the datapath ------------------------------------------
    always @(posedge clk) begin
        if (rst)                    in_flight <= 1'b0;
        else if (issue)             in_flight <= 1'b1;
        else if (mul_done)          in_flight <= 1'b0;
    end

    wire result_now = (launch & is_add) | (in_flight & mul_done);

    // ---- unload the 24-bit result, low byte first --------------------------
    // The first byte goes straight out of the datapath, so the shift register
    // only has to hold the other two.
    reg [15:0] res;
    reg [1:0]  out_rem;

    always @(posedge clk) begin
        if (rst) begin
            res       <= 16'd0;
            out_byte  <= 8'd0;
            out_valid <= 1'b0;
            out_rem   <= 2'd0;
        end else if (result_now) begin
            res       <= {b_out[11:4], b_out[3:0], a_out[11:8]};
            out_byte  <= a_out[7:0];
            out_valid <= 1'b1;
            out_rem   <= 2'd2;
        end else if (out_rem != 2'd0) begin
            res       <= {8'h00, res[15:8]};
            out_byte  <= res[7:0];
            out_valid <= 1'b1;
            out_rem   <= out_rem - 2'd1;
        end else begin
            out_valid <= 1'b0;
        end
    end

    // High from launch until the last result byte has been presented, so the
    // host can poll instead of counting clocks -- which matters here because
    // ADD finishes in one cycle and everything else takes three.
    assign busy = launch | in_flight | (out_rem != 2'd0) | out_valid;

    // only the low nibble of a high-half write is a coefficient bit
    wire _unused = &{1'b0, in_byte[7:4], 1'b0};

endmodule

`default_nettype wire
