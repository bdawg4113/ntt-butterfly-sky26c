// mod_add.v -- c = (a + b) mod q, q = 3329.
//
// Both inputs are field elements below q, so the sum is below 2q and at most
// one subtraction is ever needed. 13 bits holds it: 3328 + 3328 = 6656 < 8192.
//
// Combinational, and it stays that way: the whole block is a 13-bit add, a
// 13-bit compare and a mux -- a few nanoseconds at worst, nowhere near the
// multiplier's path.

`default_nettype none

module mod_add (
    input  wire [11:0] a,
    input  wire [11:0] b,
    output wire [11:0] c
);

    localparam [12:0] Q = 13'd3329;

    wire [12:0] sum = a + b;
    wire [12:0] sub = sum - Q;

    assign c = (sum >= Q) ? sub[11:0] : sum[11:0];

endmodule

`default_nettype wire
