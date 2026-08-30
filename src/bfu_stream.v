// bfu_stream.v -- byte-stream front end for the pipelined NTT butterfly.
//
// Tiny Tapeout gives 8 dedicated inputs and 8 dedicated outputs, which is far
// too narrow to carry a butterfly's operands in one cycle, so operands arrive
// as a 4-byte frame and results leave as a 3-byte frame.
//
//   input frame (one byte per clock, qualified by in_valid)
//     byte 0 : a[7:0]
//     byte 1 : { b[3:0], a[11:8] }
//     byte 2 : b[11:4]
//     byte 3 : { 1'b0, k[6:0] }        <- completes the frame, issues the op
//
//   output frame (one byte per clock, qualified by out_valid)
//     byte 0 : a_out[7:0]
//     byte 1 : { b_out[3:0], a_out[11:8] }
//     byte 2 : b_out[11:4]
//
// k indexes the on-chip twiddle ROM, so the host sends 7 bits instead of a
// 12-bit zeta and the frame fits in 4 bytes instead of 5.
//
// Flow control: the input bus carries at most one byte per clock, so a
// butterfly can be issued at most every 4 clocks. Results appear 4 clocks
// after issue and take 3 clocks to emit, so an output frame always finishes
// before the next result arrives. No FIFO and no backpressure are needed.

`default_nettype none

module bfu_stream (
    input  wire       clk,
    input  wire       rst,        // synchronous, active high

    input  wire [7:0] in_byte,    // operand byte bus
    input  wire       in_valid,   // in_byte carries a frame byte this clock

    output reg  [7:0] out_byte,   // result byte bus
    output reg        out_valid,  // out_byte carries a frame byte this clock
    output wire       busy        // a butterfly is in flight or emitting
);

    // ---- input frame assembly --------------------------------------------
    reg  [1:0]  in_cnt;
    reg  [11:0] a_reg;
    reg  [11:0] b_reg;
    reg  [6:0]  k_reg;
    reg         issue;

    always @(posedge clk) begin
        if (rst) begin
            in_cnt <= 2'd0;
            a_reg  <= 12'd0;
            b_reg  <= 12'd0;
            k_reg  <= 7'd0;
            issue  <= 1'b0;
        end else begin
            issue <= 1'b0;
            if (in_valid) begin
                case (in_cnt)
                    2'd0: a_reg[7:0]  <= in_byte;
                    2'd1: begin
                        a_reg[11:8] <= in_byte[3:0];
                        b_reg[3:0]  <= in_byte[7:4];
                    end
                    2'd2: b_reg[11:4] <= in_byte;
                    default: begin
                        k_reg <= in_byte[6:0];
                        issue <= 1'b1;      // frame complete
                    end
                endcase
                in_cnt <= in_cnt + 2'd1;
            end
        end
    end

    // ---- twiddle lookup and the pipelined butterfly -----------------------
    wire [11:0] zeta;
    wire [11:0] bf_a_out, bf_b_out;
    wire        bf_valid;

    twiddle_rom u_rom (
        .k    (k_reg),
        .zeta (zeta)
    );

    butterfly u_butterfly (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (issue),
        .a         (a_reg),
        .b         (b_reg),
        .zeta      (zeta),
        .a_out     (bf_a_out),
        .b_out     (bf_b_out),
        .out_valid (bf_valid)
    );

    // ---- output frame emission -------------------------------------------
    // Byte 0 goes straight out of the butterfly, so the shift register only
    // has to hold the remaining two bytes: { b_out[11:4], b_out[3:0], a_out[11:8] }.
    reg [15:0] res;
    reg [1:0]  out_rem;      // bytes still to send after the current one

    always @(posedge clk) begin
        if (rst) begin
            res       <= 16'd0;
            out_byte  <= 8'd0;
            out_valid <= 1'b0;
            out_rem   <= 2'd0;
        end else if (bf_valid) begin
            res       <= {bf_b_out, bf_a_out[11:8]};
            out_byte  <= bf_a_out[7:0];
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

    assign busy = (out_rem != 2'd0) | out_valid | issue;

endmodule

`default_nettype wire
