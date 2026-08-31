// ser_fqmul.v -- serial Montgomery multiply: fqmul(a,b) = a*b*R^-1 mod q
//
// Computes the same function as a parallel fqmul, but forms the 16x16 product
// one partial product per clock instead of in a single combinational array.
//
//   cycles 1..16   p = a * b, by shift-and-add
//   cycle  17      m = (p mod 2^16) * QINV ; t = p_hi - (m*q)_hi
//
// About 18 clocks per result, against 3 for the parallel pipelined version.
// That is deliberate: the byte-serial pin interface cannot deliver operands
// anywhere near one per clock, so multiply latency is nearly free, while the
// parallel 16x16 array cost 10,875 um2 of the area budget. Trading it for a
// 16-bit adder and a shift register is what lets the design fit a 1x2 tile.
//
// Because the multiply is multi-cycle, the operands sit still in their input
// registers for its whole duration -- so unlike the pipelined version there is
// no bypass chain to carry values across pipeline cuts, and no valid pipeline
// to keep in step. Multi-cycle removes an entire class of structure.
//
// Signed handling: for b in two's complement, bit 15 carries weight -2^15, so
// the final iteration subtracts the partial product instead of adding it.
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
                     S_RED  = 2'd2;

    reg [1:0]         state;
    reg signed [31:0] acc;      // running product
    reg signed [31:0] mcand;    // a, shifted left one place per step
    reg        [15:0] mplier;   // b, shifted right one place per step
    reg        [4:0]  cnt;      // steps remaining

    wire last = (cnt == 5'd1);

    // ---- the Montgomery reduction, one cycle -----------------------------
    // m only needs its low 16 bits, and m*q agrees with acc in those bits by
    // construction, so the subtraction cannot borrow out of them: the whole
    // reduction is a 16-bit subtract of the two top halves.
    wire signed [31:0] m_full = $signed(acc[15:0]) * QINV;
    wire signed [15:0] m      = m_full[15:0];
    wire signed [31:0] mq     = m * Q;
    wire signed [15:0] t_nxt  = acc[31:16] - mq[31:16];

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            acc    <= 32'sd0;
            mcand  <= 32'sd0;
            mplier <= 16'd0;
            cnt    <= 5'd0;
            c      <= 16'sd0;
            done   <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        acc    <= 32'sd0;
                        mcand  <= {{16{a[15]}}, a};
                        mplier <= b;
                        cnt    <= 5'd16;
                        state  <= S_MUL;
                    end
                end

                S_MUL: begin
                    // bit 15 of the multiplier has weight -2^15
                    if (mplier[0])
                        acc <= last ? (acc - mcand) : (acc + mcand);
                    mcand  <= mcand <<< 1;
                    mplier <= mplier >> 1;
                    cnt    <= cnt - 5'd1;
                    if (last) state <= S_RED;
                end

                default: begin      // S_RED
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
