// tb_butterfly.v -- standalone self-checking testbench for the pipelined
// butterfly, for waveform debugging without cocotb:
//
//   iverilog -g2012 -o sim_bf tb_butterfly.v ../src/butterfly.v \
//            ../src/mod_mult.v ../src/mod_add.v ../src/mod_sub.v && vvp sim_bf
//
// The butterfly has latency BF_LATENCY and accepts one operand set per clock,
// so expected results are held in a small shift register and compared when
// out_valid comes back.

`default_nettype none
`timescale 1ns / 1ps

module tb_butterfly;

    localparam integer Q          = 3329;
    localparam integer BF_LATENCY = 4;
    localparam integer NCASES     = 200;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         in_valid = 1'b0;
    reg  [11:0] a = 12'd0, b = 12'd0, zeta = 12'd0;
    wire [11:0] a_out, b_out;
    wire        out_valid;

    integer errors = 0;
    integer checked = 0;

    always #5 clk = ~clk;

    butterfly dut (
        .clk (clk), .rst (rst), .in_valid (in_valid),
        .a (a), .b (b), .zeta (zeta),
        .a_out (a_out), .b_out (b_out), .out_valid (out_valid)
    );

    // expected-result pipeline, same depth as the datapath
    reg [11:0] exp_a [0:BF_LATENCY-1];
    reg [11:0] exp_b [0:BF_LATENCY-1];

    integer s;
    always @(posedge clk) begin
        for (s = BF_LATENCY-1; s > 0; s = s - 1) begin
            exp_a[s] <= exp_a[s-1];
            exp_b[s] <= exp_b[s-1];
        end
        exp_a[0] <= ((a + ((zeta * b) % Q)) % Q);
        exp_b[0] <= ((a + Q - ((zeta * b) % Q)) % Q);
    end

    // check whenever a result emerges
    always @(posedge clk) begin
        if (!rst && out_valid) begin
            checked = checked + 1;
            if (a_out !== exp_a[BF_LATENCY-1] || b_out !== exp_b[BF_LATENCY-1]) begin
                errors = errors + 1;
                $display("FAIL @%0t: got (%0d,%0d) exp (%0d,%0d)",
                         $time, a_out, b_out,
                         exp_a[BF_LATENCY-1], exp_b[BF_LATENCY-1]);
            end
        end
    end

    integer i;
    initial begin
        $dumpfile("tb_butterfly.fst");
        $dumpvars(0, tb_butterfly);

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // stream operands back to back, one per clock
        for (i = 0; i < NCASES; i = i + 1) begin
            a        <= $urandom % Q;
            b        <= $urandom % Q;
            zeta     <= $urandom % Q;
            in_valid <= 1'b1;
            @(posedge clk);
        end
        in_valid <= 1'b0;
        repeat (BF_LATENCY + 2) @(posedge clk);

        if (checked != NCASES)
            $display("FAIL: expected %0d results, saw %0d", NCASES, checked);
        if (errors == 0 && checked == NCASES)
            $display("PASS: %0d pipelined butterflies, all match", checked);
        else
            $display("FAILED with %0d error(s)", errors);
        $finish;
    end

endmodule

`default_nettype wire
