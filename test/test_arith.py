# test_arith.py -- fqmul and barrett_reduce against the golden model.
#
# Both are pipelined and accept one operand set per clock, so each test streams
# operands back to back and scoreboards the results.

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

from ntt_golden import Q, fqmul, barrett_reduce, montgomery_reduce, ZETAS


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


async def reset(dut):
    dut.rst.value = 1
    dut.in_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def stream(dut, stimulus, drive, expect, latency, name):
    """Drive one operand set per clock and check results as they emerge."""
    pending = deque()
    seen = 0
    for item in list(stimulus) + [None] * (latency + 2):
        if item is None:
            dut.in_valid.value = 0
        else:
            drive(item)
            dut.in_valid.value = 1
            pending.append((item, expect(item)))

        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.out_valid.value):
            assert pending, f"{name}: result with nothing outstanding"
            item, exp = pending.popleft()
            got = s16(int(dut.c.value))
            assert got == exp, f"{name}: {item}: got {got}, expected {exp}"
            seen += 1
        await NextTimeStep()

    dut.in_valid.value = 0
    assert not pending, f"{name}: {len(pending)} results never came out"
    return seen


@cocotb.test()
async def test_fqmul(dut):
    """fqmul(a,b) == a*b*R^-1 mod q, over random and edge-case operands."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(21)
    cases = [(0, 0), (1, 1), (-1, 1), (3328, 3328), (-3328, 3328),
             (32767, 1), (-32768, 1), (1664, -1664)]
    # the shapes that actually occur: coefficient times Montgomery twiddle
    cases += [(random.randrange(-3329, 3329), random.choice(ZETAS))
              for _ in range(3000)]
    cases += [(random.randrange(-32768, 32768), random.randrange(-3329, 3329))
              for _ in range(2000)]

    def drive(it):
        dut.a.value = it[0]
        dut.b.value = it[1]

    n = await stream(dut, cases, drive, lambda it: fqmul(*it), 3, "fqmul")
    assert n == len(cases)
    dut._log.info(f"fqmul: {n} products match montgomery_reduce(a*b)")


@cocotb.test()
async def test_fqmul_is_montgomery_reduce(dut):
    """fqmul(x, 1) is a bare montgomery_reduce -- how the host strips the
    residual R factor after a transform round trip."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(22)
    cases = [(random.randrange(-32768, 32768), 1) for _ in range(1000)]

    def drive(it):
        dut.a.value = it[0]
        dut.b.value = it[1]

    n = await stream(dut, cases, drive,
                     lambda it: montgomery_reduce(it[0] * it[1]), 3, "mr")
    assert n == len(cases)
    dut._log.info(f"fqmul(x,1) == montgomery_reduce(x) over {n} values")
