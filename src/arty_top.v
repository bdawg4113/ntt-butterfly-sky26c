// arty_top -- Digilent Arty A7-100T (xc7a100tcsg324-1) board-level top for
// the self-contained NTT/INTT demo. Wraps demo_top.v (already verified: RTL
// cocotb, gate-level netlist sim, and a real Xilinx Alveo U55C run) with
// nothing but board I/O glue -- no changes to the NTT/INTT core logic at all.
//
// This targets a standalone dev board, not a PCIe-attached datacenter card,
// so there is no AXI4-Lite/XRT control path here (see demo_top_s_axi.v for
// that, Alveo-only). Control is a physical pushbutton; status is physical
// LEDs -- which, unlike the Alveo U55C, this board actually has, so this is
// the first deployment able to literally satisfy the original Phase 3
// checklist's "BRAM self-check harness ... pass/fail LED" /
// "stage-visualization output (LEDs)" items with real LEDs rather than an
// AXI-readable status register standing in for them.
//
//   BTN[0] -- press to launch one run (debounced, edge-detected into a
//             single-cycle start_i pulse)
//   BTN[1] -- press and hold to reset (synchronized, level-sensitive --
//             demo_top's own rst is synchronous active-high)
//   LED[0] -- pass_o, steady: lit = last completed run's
//             INTT(NTT(f))==f held, valid from that run's completion until
//             the next button press
//   LED[1] -- busy, stretched to ~0.25s so a ~160us-long real run (at
//             100MHz, demo_top's ~16000-cycle run) is actually visible as a
//             flash instead of an imperceptible flicker
//   LED[2] -- toggles once per completed run -- proves the design is
//             re-triggerable (alternates on successive button presses)
//             rather than a one-shot fluke
//   LED[3] -- free-running ~1Hz heartbeat, always toggling -- confirms the
//             board is powered and the clock is alive even before the first
//             button press

module arty_top #(
    // Exposed as top-level parameters (rather than overridden on the nested
    // debounce_pulse/pulse_stretch instances directly) because Icarus's
    // command-line `-P<top>.<instance>.<param>=value` override only
    // reliably reaches the literal top module's own parameters, not nested
    // instance parameters -- confirmed empirically. cocotb tests override
    // these two down to a few cycles for fast simulation; synthesis uses
    // the real board-time defaults below.
    parameter integer START_DEBOUNCE_CYCLES = 1_000_000,  // ~10ms @ 100MHz
    parameter integer BUSY_STRETCH_CYCLES   = 25_000_000  // ~0.25s @ 100MHz
) (
    input  wire       CLK100MHZ,
    input  wire [1:0] BTN,     // BTN[0] = start, BTN[1] = reset
    output wire [3:0] LED
);
    wire clk = CLK100MHZ;

    // ---- reset: 2-FF synchronizer only (level-sensitive, no debounce
    // needed -- holding rst a few extra bounce-cycles is harmless) ----
    reg rst_sync0, rst_sync1;
    always @(posedge clk) begin
        rst_sync0 <= BTN[1];
        rst_sync1 <= rst_sync0;
    end
    wire rst = rst_sync1;

    // ---- start: debounced single-cycle pulse ----
    wire start_pulse;
    debounce_pulse #(.STABLE_CYCLES(START_DEBOUNCE_CYCLES)) u_start_db (
        .clk     (clk),
        .rst     (rst),
        .btn_raw (BTN[0]),
        .pulse   (start_pulse)
    );

    // ---- the already-verified self-contained demo core ----
    wire        busy, done, pass_o;
    wire [2:0]  phase;
    wire [31:0] cycle_count;

    demo_top u_demo (
        .clk          (clk),
        .rst          (rst),
        .start_i      (start_pulse),
        .busy         (busy),
        .done         (done),
        .pass_o       (pass_o),
        .phase        (phase),
        .cycle_count  (cycle_count),
        .ext_addr_sel (1'b0),
        .ext_addr     (8'd0),
        .ext_dout     ()
    );

    // ---- LED[1]: busy, stretched to be humanly visible ----
    wire busy_led;
    pulse_stretch #(.STRETCH_CYCLES(BUSY_STRETCH_CYCLES)) u_busy_stretch (
        .clk           (clk),
        .rst           (rst),
        .in_level      (busy),
        .out_stretched (busy_led)
    );

    // ---- LED[2]: toggles once per completed run ----
    reg run_toggle;
    always @(posedge clk) begin
        if (rst) run_toggle <= 1'b0;
        else if (done) run_toggle <= ~run_toggle;
    end

    // ---- LED[3]: free-running ~1Hz heartbeat (100MHz / 2^27 ~= 0.75Hz toggle) ----
    reg [26:0] heartbeat_cnt;
    always @(posedge clk) begin
        if (rst) heartbeat_cnt <= 27'd0;
        else     heartbeat_cnt <= heartbeat_cnt + 1'b1;
    end

    assign LED[0] = pass_o;
    assign LED[1] = busy_led;
    assign LED[2] = run_toggle;
    assign LED[3] = heartbeat_cnt[26];

endmodule
