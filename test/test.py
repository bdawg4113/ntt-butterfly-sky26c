import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

@cocotb.test()
async def test_tt_wrapper(dut):
    """Smoke test to verify the NTT engine runs via the Tiny Tapeout physical pins."""
    
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    
    # 1. Initialize pins and apply active-low reset
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    
    # Release reset
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    
    dut._log.info("Reset complete. Pulsing start pin (ui_in[0]).")
    
    # 2. Pulse start pin (ui_in bit 0)
    dut.ui_in.value = 1
    await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    
    # 3. Wait for done flag (uo_out bit 0)
    cycles = 0
    max_cycles = 5000
    
    while (int(dut.uo_out.value) & 0x01) == 0:
        await RisingEdge(dut.clk)
        cycles += 1
        if cycles > max_cycles:
            dut._log.error("Timeout waiting for done signal!")
            assert False
            
    dut._log.info(f"Engine completed via external pins in {cycles} clock cycles!")
    assert (int(dut.uo_out.value) & 0x01) == 1