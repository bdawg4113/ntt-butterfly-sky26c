// montgomery_reduce.v -- signed Montgomery reduction, equation (10.1)
//
//   m = (a mod 2^16) * QINV      kept as a signed 16-bit value
//   t = (a - m*q) >>> 16         arithmetic shift
//
// Takes a signed 32-bit product a with |a| < q * 2^15 and returns
// a * R^-1 mod q with |t| < q, where R = 2^16 and QINV = q^-1 mod 2^16 = -3327.
//
// The shift is exact because m is chosen precisely so that m*q agrees with a
// in the low 16 bits. That also means the subtraction cannot borrow out of
// those bits, so the whole thing reduces to a 16-bit subtract of the two top
// halves -- no 32-bit subtractor is needed.
//
// Latency 2 clocks, one result per clock.

`default_nettype none

module montgomery_reduce (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire signed [31:0] a,          // |a| < q * 2^15
    output wire signed [15:0] t,          // a * R^-1 mod q, |t| < q
    output wire               out_valid
);

    localparam signed [15:0] QINV = -16'sd3327;   // q^-1 mod 2^16
    localparam signed [15:0] Q    =  16'sd3329;

    // ---- stage 1: m, and the top half of a carried forward ---------------
    // Only the low 16 bits of the product matter, so it does not matter
    // whether a[15:0] is read as signed or unsigned here.
    wire signed [31:0] m_full = $signed(a[15:0]) * QINV;

    reg signed [15:0] s1_m;
    reg signed [15:0] s1_a_hi;
    reg               s1_valid;

    always @(posedge clk) begin
        if (rst) begin
            s1_m     <= 16'sd0;
            s1_a_hi  <= 16'sd0;
            s1_valid <= 1'b0;
        end else begin
            s1_m     <= m_full[15:0];
            s1_a_hi  <= $signed(a[31:16]);
            s1_valid <= in_valid;
        end
    end

    // ---- stage 2: t = a_hi - (m*q)_hi ------------------------------------
    wire signed [31:0] mq    = s1_m * Q;
    wire signed [15:0] t_nxt = s1_a_hi - mq[31:16];

    reg signed [15:0] s2_t;
    reg               s2_valid;

    always @(posedge clk) begin
        if (rst) begin
            s2_t     <= 16'sd0;
            s2_valid <= 1'b0;
        end else begin
            s2_t     <= t_nxt;
            s2_valid <= s1_valid;
        end
    end

    assign t         = s2_t;
    assign out_valid = s2_valid;

    // the low half of m*q is cancelled by construction and never read
    wire _unused = &{1'b0, mq[15:0], m_full[31:16], 1'b0};

endmodule

`default_nettype wire
