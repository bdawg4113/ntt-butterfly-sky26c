/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_ntt (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
  //============== Interconnects =================================================================
  wire start_sig  = ui_in[0];
  wire done_sig;

  //============== NTT Engine Instantiation ======================================================
  ntt_top u_ntt_top(
    .clk      (clk),
    .rst      (~rst_n),         // our design uses an active high reset, TT uses active low rst
    .start    (start_sig), 
    .done     (done_sig)
  );



  //=============== Output Pin Assignments =======================================================
  // Map done flag to bit 0, ground the rest: 

  assign uo_out[0]  = done_sig;
  assign uo_out[7:1] = 7'b0000000;  

  // Disable bidirectional io pins: 
  assign uio_oe  = 8'b00000000;
  assign uio_out = 8'b00000000;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, clk, rst_n, 1'b0};

endmodule
