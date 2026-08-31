// ser_fqmul.v -- serial Montgomery multiply: fqmul(a,b) = a*b*R^-1 mod q
//
//   cycles 1..16   p = a * b, one partial product per clock
//   cycle  17      m = (p mod 2^16) * QINV
//   cycle  18      t = p_hi - (m*q)_hi
//
// About 19 clocks per result. That is deliberate: the byte-serial pin interface
// cannot deliver operands anywhere near one per clock, so multiply latency is
// nearly free, while a parallel 16x16 array cost 10,875 um2 -- most of a 1x2
// tile's usable area on its own.
//
// ---------------------------------------------------------------------------
// Why the accumulator shifts right rather than the multiplicand shifting left
// ---------------------------------------------------------------------------
// The obvious serial multiplier holds a 32-bit accumulator and shifts the
// multiplicand up into it. That needs a 32-bit adder, and its ripple carry has
// to settle in one clock. Post-layout timing on exactly that structure put the
// worst path at 21.67 ns against a 20 ns period -- a setup violation of
// 0.97 ns at the slow corner, right through acc[3] and up the carry chain.
//
// This version keeps the classic shift-right form instead: the accumulator A
// holds only the top half, the multiplier register Q doubles as the bottom half
// of the product, and the pair shifts right one place per step. The adder is
// then 17 bits rather than 32, halving the carry chain, and the multiplicand
// register M stops shifting so it stays 16 bits wide. Shorter path and less
// area from one restructuring.
//
// The Montgomery reduction is also split across two clocks rather than one.
// Folding both constant multiplies (by QINV, then by q) into a single cycle
// chains them, and with the adder path now shorter that chain would have become
// the critical path in its place.
//
// Signed handling: for b in two's complement bit 15 carries weight -2^15, so
// the final step subtracts the partial product instead of adding it.
//
//   |a*b| < q * 2^15 must hold for the reduction to be exact, and |t| < q.

`default_nettype none

module ser_fqmul (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,      // one-clock pulse; ignored while busy
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    output reg  signed [15:0] c,
    output reg                done,       // one-clock pulse: c is valid
    output wire               busy
);

    localparam signed [15:0] QINV = -16'sd3327;   // q^-1 mod 2^16
    localparam signed [15:0] Q    =  16'sd3329;

    localparam [1:0] S_IDLE = 2'd0,
                     S_MUL  = 2'd1,
                     S_RED1 = 2'd2,
                     S_RED2 = 2'd3;

    reg [1:0]         state;
    reg signed [16:0] acc;      // running product, top half (one spare bit for carry)
    reg        [15:0] qr;       // multiplier, and the bottom half of the product
    reg signed [15:0] mcand;    // multiplicand; does not shift
    reg        [4:0]  cnt;      // steps remaining
    reg signed [15:0] m;        // Montgomery factor, held between the two reduce steps

    wire last = (cnt == 5'd1);

    // ---- one multiply step ------------------------------------------------
    // 17-bit add, then the 33-bit pair {acc, qr} shifts right one place.
    wire signed [16:0] mcand_ext = {mcand[15], mcand};
    wire signed [16:0] addend    = qr[0] ? (last ? -mcand_ext : mcand_ext)
                                         : 17'sd0;
    wire signed [16:0] sum       = acc + addend;

    // ---- the reduction ----------------------------------------------------
    // After the loop the product is {acc[15:0], qr}: qr holds its low 16 bits
    // and acc its high 16. m only needs its low 16 bits, and m*q agrees with
    // the product in exactly those bits by construction, so the subtraction
    // cannot borrow out of them -- the reduction is a 16-bit subtract of the
    // two top halves, never a 32-bit one.
    wire signed [31:0] m_full = $signed(qr) * QINV;
    wire signed [31:0] mq     = m * Q;
    wire signed [15:0] t_nxt  = acc[15:0] - mq[31:16];

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            acc   <= 17'sd0;
            qr    <= 16'd0;
            mcand <= 16'sd0;
            cnt   <= 5'd0;
            m     <= 16'sd0;
            c     <= 16'sd0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        acc   <= 17'sd0;
                        qr    <= b;
                        mcand <= a;
                        cnt   <= 5'd16;
                        state <= S_MUL;
                    end
                end

                S_MUL: begin
                    acc <= {sum[16], sum[16:1]};    // arithmetic shift right
                    qr  <= {sum[0], qr[15:1]};      // sum's LSB becomes the product's next bit
                    cnt <= cnt - 5'd1;
                    if (last) state <= S_RED1;
                end

                S_RED1: begin
                    m     <= m_full[15:0];
                    state <= S_RED2;
                end

                default: begin      // S_RED2
                    c     <= t_nxt;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // only the low half of m*q is cancelled by construction and never read
    wire _unused = &{1'b0, mq[15:0], m_full[31:16], 1'b0};

endmodule

`default_nettype wire
