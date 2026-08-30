# test_ntt_top.py -- full functional check of the pipelined NTT engine.
#
# 1. preload coeff_mem from init_coeffs.hex (done by $readmemh in the RTL)
# 2. run the engine to completion
# 3. run the same input through the Python golden model
# 4. compare all 256 coefficients

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from ntt_golden import ntt

MAX_CYCLES = 4000          # pipelined engine needs ~940; old one needed 3586


@cocotb.test()
async def test_ntt_formal_verification(dut):
    """Full functional verification of ntt_top against the Python golden model."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    # capture the preloaded contents before the engine overwrites them, so the
    # golden model is fed exactly what the RTL started from
    dut.rst.value = 1
    dut.start.value = 0
    await ClockCycles(dut.clk, 5)
    initial_coeffs = [int(dut.u_mem.mem[i].value) for i in range(256)]
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)

    assert len(initial_coeffs) == 256
    assert all(0 <= c < 3329 for c in initial_coeffs), \
        "preloaded coefficients must all be reduced mod q"

    dut._log.info("Reset complete. Asserting start.")
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    cycles = 0
    while int(dut.done.value) == 0:
        await RisingEdge(dut.clk)
        cycles += 1
        assert cycles < MAX_CYCLES, f"done never asserted within {MAX_CYCLES} cycles"

    dut._log.info(f"NTT engine completed in {cycles} clock cycles.")

    expected = ntt(initial_coeffs)
    rtl = [int(dut.u_mem.mem[i].value) for i in range(256)]

    mismatches = [(i, rtl[i], expected[i]) for i in range(256) if rtl[i] != expected[i]]
    for i, got, exp in mismatches[:16]:
        dut._log.error(f"Mismatch at index {i}: RTL={got}, golden={exp}")
    assert not mismatches, \
        f"Verification FAILED: {len(mismatches)}/256 coefficients differ"

    dut._log.info("SUCCESS: all 256 coefficients match the golden model.")


@cocotb.test()
async def test_ntt_is_rerunnable(dut):
    """A second start must transform the (already transformed) contents again."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.rst.value = 1
    dut.start.value = 0
    await ClockCycles(dut.clk, 5)
    coeffs = [int(dut.u_mem.mem[i].value) for i in range(256)]
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)

    for run in range(2):
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0

        # done is sticky: it stays high after a run until the next start clears
        # it. Wait for that to happen before polling, or we would immediately
        # see the previous run's done and read the memory mid-transform.
        clearing = 0
        while int(dut.done.value) == 1:
            await RisingEdge(dut.clk)
            clearing += 1
            assert clearing < 10, f"run {run}: start did not clear done"

        cycles = 0
        while int(dut.done.value) == 0:
            await RisingEdge(dut.clk)
            cycles += 1
            assert cycles < MAX_CYCLES, f"run {run}: done never asserted"
        coeffs = ntt(coeffs)
        rtl = [int(dut.u_mem.mem[i].value) for i in range(256)]
        assert rtl == coeffs, f"run {run}: engine diverged from golden model"
        dut._log.info(f"run {run}: {cycles} cycles, all 256 coefficients match")
        await ClockCycles(dut.clk, 3)
