`default_nettype none 

module ntt_top(
    input wire      clk,
    input wire      rst,
    input wire      start,
    output wire     done
);
    //========Internal interconnect wires==================

    // FSM to Memory:
    wire [7:0]  r_addr_a, r_addr_b;
    wire [7:0]  w_addr_a, w_addr_b;
    wire        we; 

    //FSM to ROM: 
    wire [6:0]  k_idx;

    // Memory to butterfly: 
    wire [11:0] mem_dout_a, mem_dout_b;

    // ROM to Butterfly: 
    wire [11:0] rom_zeta;

    // Butterfly to Memory: 
    wire [11:0] bf_a_out, bf_b_out; 

    //==========Instantiate Modules=====================

    // 1. Control FSM: 

    control_fsm u_fsm(
        .clk    (clk),
        .rst    (rst),
        .start  (start),
        .r_addr_a   (r_addr_a),
        .r_addr_b   (r_addr_b),
        .w_addr_a   (w_addr_a),
        .w_addr_b   (w_addr_b),
        .we         (we),
        .k_idx      (k_idx),
        .done       (done)

    );

    // 2. Coefficient Memory
    coeff_mem u_mem (
        .clk      (clk),
        .rst      (rst),
        .we       (we),
        .r_addr_a (r_addr_a),
        .r_addr_b (r_addr_b),
        .w_addr_a (w_addr_a),
        .w_addr_b (w_addr_b),
        .din_a    (bf_a_out),
        .din_b    (bf_b_out),
        .dout_a   (mem_dout_a),
        .dout_b   (mem_dout_b)
    );

    // 3. Twiddle Factor ROM
    twiddle_rom u_rom (
        .k    (k_idx),
        .zeta (rom_zeta)
    );

    // 4. Butterfly Datapath
    butterfly u_butterfly (
        .a     (mem_dout_a),
        .b     (mem_dout_b),
        .zeta  (rom_zeta),
        .a_out (bf_a_out),
        .b_out (bf_b_out)
    );

endmodule