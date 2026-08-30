// mod_add.v -- c = (a + b) mod q, q = 3329
//
// Both inputs are field elements < q, so a + b < 2q and at most one
// conditional subtraction is needed. Combinational.

`default_nettype none

module mod_add (
    input  wire [11:0] a,
    input  wire [11:0] b,
    output wire [11:0] c
);

    localparam [12:0] Q = 13'd3329;

    wire [12:0] sum = {1'b0, a} + {1'b0, b};   // max 3328+3328 = 6656, needs 13 bits
    wire        ge  = (sum >= Q);

    // When sum >= q the true result sum-q lies in [0, 3327], so evaluating the
    // subtract in 12 bits is exact: the discarded bit 12 cannot affect it.
    assign c = ge ? (sum[11:0] - Q[11:0]) : sum[11:0];

endmodule

`default_nettype wire
