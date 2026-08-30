// mod_sub.v -- c = (a - b) mod q, q = 3329
//
// q is added first so the intermediate never underflows and everything stays
// unsigned: for a, b < q the value a + q - b lies in [1, 2q]. Combinational.

`default_nettype none

module mod_sub (
    input  wire [11:0] a,
    input  wire [11:0] b,
    output wire [11:0] c
);

    localparam [12:0] Q = 13'd3329;

    wire [12:0] diff = ({1'b0, a} + Q) - {1'b0, b};   // in [1, 6657], never negative
    wire        ge   = (diff >= Q);

    // When diff >= q the true result diff-q lies in [0, 3328], so the 12-bit
    // subtract is exact; otherwise diff is already < q and fits in 12 bits.
    assign c = ge ? (diff[11:0] - Q[11:0]) : diff[11:0];

endmodule

`default_nettype wire
