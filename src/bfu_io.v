// bfu_io.v -- byte-serial front end for the NTT/INTT arithmetic core.
//
// Tiny Tapeout gives 8 data inputs, 8 data outputs and 8 bidirectional pins,
// which is far narrower than the 48-bit operand vector (a, b, zeta) a butterfly
// needs. The host therefore assembles operands by addressed byte writes, pulses
// start, waits for busy to fall, and shifts the 32-bit result back out a byte
// at a time.
//
//   writing:  put a byte on in_byte, its register number on waddr, raise we
//
//     addr 0  a[7:0]        addr 4  zeta[7:0]
//     addr 1  a[15:8]       addr 5  zeta[15:8]
//     addr 2  b[7:0]        addr 6  ctrl = { 5'b0, mode[2:0] }
//     addr 3  b[15:8]
//
//   executing: a rising edge on start launches one operation. busy stays high
//              until the last result byte has been presented. The operand
//              registers must not be written while busy, since the core reads
//              them directly for the whole operation.
//
//   reading:  four bytes come back on out_byte, each qualified by out_valid,
//             low byte first:  a_out[7:0], a_out[15:8], b_out[7:0], b_out[15:8]
//
// The twiddle factor is supplied by the host as a full 16-bit value. There is
// no on-chip twiddle ROM: the host already holds the table, a ROM cost 2,198
// um2 of a tight area budget, and sending zeta directly is what basemul needs
// anyway, since its twiddles are the signed pair +/-zetas[64+i].
//
// Registers persist between operations, so a host walking one NTT layer only
// rewrites the bytes that actually changed -- usually just the four operand
// bytes, since zeta and mode are constant across a whole layer.

`default_nettype none

module bfu_io (
    input  wire       clk,
    input  wire       rst,          // synchronous, active high

    input  wire [7:0] in_byte,      // write data
    input  wire [2:0] waddr,        // register select
    input  wire       we,           // write strobe
    input  wire       start,        // rising edge launches one operation

    output reg  [7:0] out_byte,     // result byte
    output reg        out_valid,    // out_byte is live this clock
    output wire       busy          // operation in flight, or result unloading
);

    // ---- operand registers -----------------------------------------------
    reg signed [15:0] a_reg, b_reg, zeta_reg;
    reg        [2:0]  mode_reg;

    always @(posedge clk) begin
        if (rst) begin
            a_reg    <= 16'sd0;
            b_reg    <= 16'sd0;
            zeta_reg <= 16'sd0;
            mode_reg <= 3'd0;
        end else if (we) begin
            case (waddr)
                3'd0: a_reg[7:0]     <= in_byte;
                3'd1: a_reg[15:8]    <= in_byte;
                3'd2: b_reg[7:0]     <= in_byte;
                3'd3: b_reg[15:8]    <= in_byte;
                3'd4: zeta_reg[7:0]  <= in_byte;
                3'd5: zeta_reg[15:8] <= in_byte;
                3'd6: mode_reg       <= in_byte[2:0];
                default: ;           // addr 7 reserved
            endcase
        end
    end

    // ---- launch on the rising edge of start -------------------------------
    reg  start_d;
    wire issue = start & ~start_d;

    always @(posedge clk) begin
        if (rst) start_d <= 1'b0;
        else     start_d <= start;
    end

    // ---- the arithmetic core ----------------------------------------------
    wire signed [15:0] core_a, core_b;
    wire               core_valid;
    wire               core_busy;

    bfu_core u_core (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (issue),
        .mode      (mode_reg),
        .a         (a_reg),
        .b         (b_reg),
        .zeta      (zeta_reg),
        .a_out     (core_a),
        .b_out     (core_b),
        .out_valid (core_valid),
        .busy      (core_busy)
    );

    // ---- unload the 32-bit result, low byte first -------------------------
    // The first byte goes straight out of the core, so the shift register only
    // has to hold the other three.
    reg [23:0] res;
    reg [1:0]  out_rem;

    always @(posedge clk) begin
        if (rst) begin
            res       <= 24'd0;
            out_byte  <= 8'd0;
            out_valid <= 1'b0;
            out_rem   <= 2'd0;
        end else if (core_valid) begin
            res       <= {core_b, core_a[15:8]};
            out_byte  <= core_a[7:0];
            out_valid <= 1'b1;
            out_rem   <= 2'd3;
        end else if (out_rem != 2'd0) begin
            res       <= {8'h00, res[23:8]};
            out_byte  <= res[7:0];
            out_valid <= 1'b1;
            out_rem   <= out_rem - 2'd1;
        end else begin
            out_valid <= 1'b0;
        end
    end

    // High from launch until the last result byte has been presented, so the
    // host can poll instead of counting clocks -- which matters here because
    // the operation length depends on the mode.
    assign busy = issue | core_busy | (out_rem != 2'd0) | out_valid;

endmodule

`default_nettype wire
