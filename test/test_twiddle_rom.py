# test_twiddle_rom.py -- the on-chip twiddle table.
#
# The ROM is 1,536 bits of hand-generated constants, and a wrong entry does not
# announce itself: the transform still runs, still terminates, and produces a
# result that looks like noise in exactly the same way a correct NTT of random
# input does. So every one of the 128 entries is read and checked, not a sample.
#
# The table is also checked against the FIPS 203 definition directly --
# zeta[k] = 17^brv7(k) mod q -- rather than only against the generator script,
# because the generator and the ROM share an author and would share a mistake.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from ntt_golden import Q, ZETAS


def _brv7(i):
    r = 0
    for b in range(7):
        r = (r << 1) | ((i >> b) & 1)
    return r


@cocotb.test()
async def test_every_entry(dut):
    """All 128 entries, against 17^brv7(k) mod q computed here from scratch."""
    for k in range(128):
        dut.k.value = k
        await Timer(1, unit="ns")
        got = int(dut.zeta.value)
        exp = pow(17, _brv7(k), Q)
        assert got == exp, f"zeta[{k}]: ROM has {got}, FIPS 203 says {exp}"
        assert got == ZETAS[k], f"zeta[{k}] disagrees with the golden model"
    dut._log.info("all 128 twiddles match 17^brv7(k) mod q")


@cocotb.test()
async def test_table_is_plain_not_montgomery(dut):
    """The entries must be plain field elements, not Montgomery form.

    This is the single most costly mistake available in this design: a
    Montgomery table is the same width and the same shape, and a Barrett
    datapath fed with one produces a transform that is wrong by a factor of
    R^-1 at every butterfly while remaining perfectly self-consistent. Pin it
    down with a value that cannot be confused: zeta[1] is 1729 in plain form
    and 2571 (i.e. -758 mod q) in Montgomery form.
    """
    dut.k.value = 1
    await Timer(1, unit="ns")
    got = int(dut.zeta.value)
    mont = (1729 * (1 << 16)) % Q
    assert got == 1729, f"zeta[1] = {got}; plain is 1729, Montgomery would be {mont}"
    assert got != mont
    dut._log.info(f"zeta[1] = 1729: the table is plain, not Montgomery ({mont})")


@cocotb.test()
async def test_all_entries_are_field_elements(dut):
    """Every entry must be a reduced field element, and all 128 distinct --
    17 has order 256 mod q, so a repeat would mean the index order is wrong."""
    seen = []
    for k in range(128):
        dut.k.value = k
        await Timer(1, unit="ns")
        z = int(dut.zeta.value)
        assert 0 < z < Q, f"zeta[{k}] = {z} is not a reduced field element"
        seen.append(z)
    assert len(set(seen)) == 128, "the table contains duplicates"
    dut._log.info("128 distinct entries, all in [1, q)")
