// bfu_io.v -- byte-serial front end for the NTT/INTT arithmetic core.
//
// Tiny Tapeout gives 8 data inputs, 8 data outputs and 8 bidirectional pins,
// which is far narrower than the 48-bit operand vector (a, b, zeta) a butterfly
// needs. The host therefore assembles operands by addressed byte writes, pulses
// start, and shifts the 32-bit result back out a byte at a time.
//
//   writing:  put a byte on in_byte, its register number on waddr, raise we
//
//     addr 0  a[7:0]        addr 4  zeta[7:0]
//     addr 1  a[15:8]       addr 5  zeta[15:8]
//     addr 2  b[7:0]        addr 6  ctrl = { 4'b0, zeta_from_rom, mode[2:0] }
//     addr 3  b[15:8]
//
//   executing: a rising edge on start latches the operand vector into the core
//
//   reading:  four bytes come back on out_byte, each qualified by out_valid,
//             low byte first:  a_out[7:0], a_out[15:8], b_out[7:0], b_out[15:8]
//
// ctrl bit 3 (zeta_from_rom) selects where the twiddle comes from. Cleared, the
// core uses the 16-bit value the host wrote -- which is what basemul needs,
// since its twiddles are the signed pair +/-zetas[64+i]. Set, the core looks up
// zetas[zeta[6:0]] in the on-chip ROM, so a transform only has to send an index
// rather than a full coefficient.
//
// Registers persist between operations, so a host walking one NTT layer only
// rewrites the bytes that actually changed.

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
    output wire       busy          // an operation is in flight or unloading
);

    localparam integer CORE_LATENCY = 5;

    // ---- operand registers -----------------------------------------------
    reg signed [15:0] a_reg, b_reg, zeta_reg;
    reg        [3:0]  ctrl_reg;     // {zeta_from_rom, mode[2:0]}

    always @(posedge clk) begin
        if (rst) begin
            a_reg    <= 16'sd0;
            b_reg    <= 16'sd0;
            zeta_reg <= 16'sd0;
            ctrl_reg <= 4'd0;
        end else if (we) begin
            case (waddr)
                3'd0: a_reg[7:0]     <= in_byte;
                3'd1: a_reg[15:8]    <= in_byte;
                3'd2: b_reg[7:0]     <= in_byte;
                3'd3: b_reg[15:8]    <= in_byte;
                3'd4: zeta_reg[7:0]  <= in_byte;
                3'd5: zeta_reg[15:8] <= in_byte;
                3'd6: ctrl_reg       <= in_byte[3:0];
                default: ;           // addr 7 reserved
            endcase
        end
    end

    // ---- twiddle source ---------------------------------------------------
    wire [2:0]        mode          = ctrl_reg[2:0];
    wire              zeta_from_rom = ctrl_reg[3];

    wire signed [15:0] rom_zeta;
    twiddle_rom u_rom (
        .k    (zeta_reg[6:0]),
        .zeta (rom_zeta)
    );

    wire signed [15:0] zeta_eff = zeta_from_rom ? rom_zeta : zeta_reg;

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

    bfu_core u_core (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (issue),
        .mode      (mode),
        .a         (a_reg),
        .b         (b_reg),
        .zeta      (zeta_eff),
        .a_out     (core_a),
        .b_out     (core_b),
        .out_valid (core_valid)
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

    // ---- in-flight tracking ----------------------------------------------
    // High from the moment an operation is launched until its last result byte
    // has been presented, so the host can poll instead of counting clocks.
    reg [2:0] inflight;
    always @(posedge clk) begin
        if (rst)                          inflight <= 3'd0;
        else if (issue)                   inflight <= CORE_LATENCY[2:0];
        else if (inflight != 3'd0)        inflight <= inflight - 3'd1;
    end

    assign busy = (inflight != 3'd0) | (out_rem != 2'd0) | out_valid;

endmodule

`default_nettype wire
