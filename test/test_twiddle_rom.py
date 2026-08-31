# test_twiddle_rom.py -- every entry of the Montgomery-form twiddle ROM.
import cocotb
from cocotb.triggers import Timer

from ntt_golden import ZETAS, s16


@cocotb.test()
async def test_twiddle_rom(dut):
    """All 128 entries must equal zeta^brv7(k) * R mod q, centred."""
    for k in range(128):
        dut.k.value = k
        await Timer(1, unit="ns")
        got = s16(int(dut.zeta.value))
        assert got == ZETAS[k], f"ROM[{k}]: got {got}, expected {ZETAS[k]}"

    # this table is the reference Kyber `zetas` array
    dut.k.value = 0
    await Timer(1, unit="ns")
    assert s16(int(dut.zeta.value)) == -1044, "ROM[0] should be R mod q = -1044"
    dut._log.info("twiddle ROM: all 128 Montgomery-form entries verified")
