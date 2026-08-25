# test_ntt_top.py

# tests ntt_top.v in /src.

# 1. reads all initial mem values in the init_coeffs.hex file 
# 2. Compares generated output values of ntt_top.v 
# 3. extracts the RTL values of ntt_top.v 
# 4. checks to see if the RTL Values from running the testbench are the same as the golden model 

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from ntt_golden import ntt

@cocotb.test()
async def test_ntt_formal_verification(dut):
    """Full functional verification of the NTT top-level engine against the Python Golden Model."""
    
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    
    # Apply Reset
    dut.rst.value = 1
    dut.start.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)
    
    dut._log.info("Reset complete. Asserting start signal.")
    
    # Pulse Start Signal
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    
    # Monitor Execution
    cycles = 0
    while int(dut.done.value) == 0:
        await RisingEdge(dut.clk)
        cycles += 1
            
    dut._log.info(f"NTT Engine completed successfully in {cycles} clock cycles!")
    assert int(dut.done.value) == 1
    
    # ==========================================
    # Formal Verification Block
    # ==========================================
    dut._log.info("Starting Formal Verification...")
    
    # 1. Read initial values from hex file
    initial_coeffs = []
    try:
        with open("init_coeffs.hex", "r") as f:
            for line in f:
                initial_coeffs.append(int(line.strip(), 16))
    except FileNotFoundError:
        dut._log.error("init_coeffs.hex not found. Did you run generate_hex.py?")
        assert False
        
    assert len(initial_coeffs) == 256, "Hex file must contain exactly 256 coefficients."

    # 2. Run Python Golden Model
    expected_results = ntt(initial_coeffs)
    
    # 3. Extract RTL Memory
    rtl_results = []
    for i in range(256):
        val = int(dut.u_mem.mem[i].value)
        rtl_results.append(val)
        
    # 4. Compare
    mismatches = 0
    for i in range(256):
        if rtl_results[i] != expected_results[i]:
            dut._log.error(f"Mismatch at index {i}: RTL={rtl_results[i]}, Golden={expected_results[i]}")
            mismatches += 1
            
    if mismatches > 0:
        dut._log.error(f"Verification FAILED with {mismatches} mismatched coefficients.")
        assert False
    else:
        dut._log.info("SUCCESS: RTL perfectly matches the Python Golden Model across all 256 coefficients!")