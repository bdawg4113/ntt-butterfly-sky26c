# test_barrett.py -- barrett_reduce against the golden model.
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

from ntt_golden import Q, barrett_reduce


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


@cocotb.test()
async def test_barrett_reduce(dut):
    """barrett(a) is congruent to a mod q and lands in a centred range."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.rst.value = 1
    dut.in_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    random.seed(23)
    cases = [0, 1, -1, 3329, -3329, 32767, -32768, 18504, -18504]
    cases += [random.randrange(-32768, 32768) for _ in range(4000)]

    pending = deque()
    seen = 0
    for item in cases + [None] * 5:
        if item is None:
            dut.in_valid.value = 0
        else:
            dut.a.value = item
            dut.in_valid.value = 1
            pending.append(item)

        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.out_valid.value):
            a = pending.popleft()
            got = s16(int(dut.c.value))
            exp = barrett_reduce(a)
            assert got == exp, f"barrett({a}): got {got}, expected {exp}"
            assert (got - a) % Q == 0, f"barrett({a}) changed the residue"
            assert abs(got) <= Q, f"barrett({a}) = {got} not centred"
            seen += 1
        await NextTimeStep()

    assert not pending and seen == len(cases)
    dut._log.info(f"barrett_reduce: {seen} values congruent mod q and centred")
