// mod_sub.v -- c = (a - b) mod q, q = 3329.
//
// q is added before the subtraction so the intermediate never goes negative
// and the whole block can stay unsigned: with a, b < q, the value a + q - b
// lies in [1, 2q], so one conditional subtract finishes it.
//
// Combinational. Two of these are instantiated in butterfly.v -- one before
// the multiplier and one after -- and neither is anywhere near critical.

`default_nettype none

module mod_sub (
    input  wire [11:0] a,
    input  wire [11:0] b,
    output wire [11:0] c
);

    localparam [12:0] Q = 13'd3329;

    wire [12:0] diff = (a + Q) - b;    // in [1, 2q], never borrows
    wire [12:0] sub  = diff - Q;

    assign c = (diff >= Q) ? sub[11:0] : diff[11:0];

endmodule

`default_nettype wire
