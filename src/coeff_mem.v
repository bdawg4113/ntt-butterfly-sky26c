// Coeff memory stores 256 coefficients of the polynomial to be multiplied when the butterfly runs 

// 256 coefficients per each bit of the system, 12 bits wide. 

// tasks: 
// 1. read two coeffs: f[j] and f[j+len] at the addresses of the controller FSM 
//      these become the butterfly's a and b 
// 2. Write two coeffs back: a_out to address j and b_out to address j+len - after the butterfly computes 

//Schematic capture: 

//                    ┌──────────────────┐
//   addr_a (from FSM)│                  │ dout_a ──► butterfly.a
//   addr_b (from FSM)│  coeff memory    │ dout_b ──► butterfly.b
//                    │   256 × 12       │
// butterfly.a_out ──►│                  │
// butterfly.b_out ──►│                  │
//   we (write enable)│                  │
//                    └──────────────────┘

module coeff_mem(
    input  wire clk, 
    input  wire we,          // write enable  
    input  wire rst,         // reset pin     
    input  wire [7:0] r_addr_a,    // = j
    input  wire [7:0] r_addr_b,    // = j + len 
    input  wire [7:0] w_addr_a,    // write address for butterfly a_out 
    input  wire [7:0] w_addr_b,    // write address for butterfly b_out 
    input  wire [11:0] din_a,      // butterfly a_out 
    input  wire [11:0] din_b,      // butterfly b_out 
    output wire [11:0] dout_a,     // data out --> butterfly_a
    output wire [11:0] dout_b      // data out --> butterfly_b
);

    reg [11:0] mem [0:255]; 

    // Memory initialization to verify FIPS 203: 
    // Load 256 known coeffs into memory block before test_ntt_top.py asserts the start signal: 

    initial begin 
        $readmemh("../test/init_coeffs.hex", mem);
    end

    // combinational reads: available same cycle as address
    assign dout_a = mem[r_addr_a];
    assign dout_b = mem[r_addr_b];

    // clocked writes: both mem for addr a and b are read on the posedge

    //rst 
    always @(posedge clk) begin 
        if (we && !rst) begin 
            mem[w_addr_a] <= din_a; 
            mem[w_addr_b] <= din_b;
        end
    end

endmodule
