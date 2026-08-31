# test_serfq.py -- the serial Montgomery multiply against the golden model.
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep
from ntt_golden import Q, ZETAS, fqmul, montgomery_reduce, R_MOD_Q


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


async def one(dut, a, b):
    dut.a.value = a
    dut.b.value = b
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    n = 0
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        d = int(dut.done.value)
        val = s16(int(dut.c.value))
        await NextTimeStep()
        n += 1
        if d:
            return val, n
        assert n < 40, "serial multiply never finished"


@cocotb.test()
async def test_ser_fqmul(dut):
    """fqmul(a,b) == a*b*R^-1 mod q for the shapes that actually occur."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    random.seed(51)
    cases = [(0, 0), (1, 1), (-1, 1), (1, -1), (-1, -1),
             (3328, 3328), (-3328, 3328), (32767, 1), (-32768, 1),
             (16628, R_MOD_Q), (-16628, R_MOD_Q), (1664, -1664)]
    cases += [(random.randrange(-3329, 3329), random.choice(ZETAS)) for _ in range(400)]
    cases += [(random.randrange(-32768, 32768), R_MOD_Q) for _ in range(200)]
    cases += [(random.randrange(-18000, 18000), random.randrange(-3329, 3329))
              for _ in range(400)]

    cycles = None
    for a, b in cases:
        got, n = await one(dut, a, b)
        exp = fqmul(a, b)
        assert got == exp, f"fqmul({a},{b}): got {got}, expected {exp}"
        if cycles is None:
            cycles = n
        assert n == cycles, f"variable latency: {n} vs {cycles}"

    dut._log.info(f"serial fqmul: {len(cases)} products correct, {cycles} clocks each")


@cocotb.test()
async def test_ser_is_montgomery_reduce(dut):
    """b = 1 gives a bare montgomery_reduce; b = R mod q gives a range reduction."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    random.seed(52)
    for _ in range(200):
        x = random.randrange(-32768, 32768)
        got, _ = await one(dut, x, 1)
        assert got == montgomery_reduce(x), f"montgomery_reduce({x})"
    for _ in range(200):
        x = random.randrange(-32768, 32768)
        got, _ = await one(dut, x, R_MOD_Q)
        assert (got - x) % Q == 0 and abs(got) < Q, \
            f"reduce({x}) = {got} not a valid centred representative"
    dut._log.info("b=1 is montgomery_reduce; b=R mod q is a range reduction")
