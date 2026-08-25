//Cooley Tukey Algorithm (top level module) for ML-KEM NTT

// t = zeta * b mod q (twiddle multiply) 
// a_out = a + t mod q (upper output, -> f[j])

// b_out = a - t mod q (lower output, -> f[j+len]) 

// Pure structural composition of three verified combinational blocks. 

// 'a' fans out to both adder and subtractor
//'b' only enters the multiply 

// Combinational (no clock yet - pipelining added in later revisions) 
// main top wrapper for mod_mult, mod_add, and mod_sub. 

// is a submodule for ntt_top.v, that combines coeff_mem, control_fsm, twiddle_rom, and butterfly into one top wrapper module 
module butterfly(
    input wire [11:0] a,        //f[j]
    input wire [11:0] b,        //f[j+len]
    input wire [11:0] zeta,     //twiddle factor 

    output wire [11:0] a_out,    //f[j] after butterfly 
    output wire [11:0] b_out    // f[j+len] after butterfly 

); 
    wire [11:0] t;      // zeta * b mod q 

    //.... mod_mult, mod_add, mod_sub pin wrappers
     mod_mult u_mult (
        .a (zeta),
        .b (b),
        .c (t)
    );
 
    mod_add u_add (
        .a (a),
        .b (t),
        .c (a_out)
    );
 
    mod_sub u_sub (
        .a (a),
        .b (t),
        .c (b_out)
    );
endmodule

