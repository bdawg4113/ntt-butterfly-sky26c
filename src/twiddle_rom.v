module twiddle_rom(
    input [6:0] addr,       // 7 bit wide addr
    input [127:0] lut,      // 128 x 12 LUT
                            // ROM[1] = 1729... ROM[127] 
    output [11:0] zeta      // 12 bit wide ROM factor 

    

);

    
endmodule