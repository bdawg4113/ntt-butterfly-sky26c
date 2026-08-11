// mod_mult 

// performs Barrett reduction without a divider 

// c = (a * b) mod q, q = 3329 

// constants: 

// k = 24, mu = floor(2^24/q) = 5039, one cond. sub

// Purely combinational, pipeline registers added in later once STA flags the path 

module mod_mult(
    input wire [11:0] a,    //field element, < 3329
    input wire [11:0] b,    //field element, < 3329 
    output wire [11:0] c    // (a*b) mod 3329, < 3329 
); 
    
    localparam [12:0] Q = 13'd3329; 
    localparam [12:0] MU = 13'd5039;        //floor(2^24/q)
    localparam integer K = 24; 

    wire [23:0] T = a * b;                          // product, up to 24 bits
    wire [36:0] T_mu = T * MU;                      // for Barrett quotient estimate
    wire [12:0] quo = T_mu[36:K];                   // > 24, quotient estimate
    wire [25:0] quo_q = quo * Q;                    
    wire [12:0] r = T[12:0] - quo_q[12:0];          // remainder, in [0, 2q]

    wire [12:0] r_minus_q = r - Q;                  
    wire ge_q = (r >= Q); 
    wire [12:0] r_final = ge_q ? r_minus_q : r;     

    assign c = r_final[11:0];

endmodule