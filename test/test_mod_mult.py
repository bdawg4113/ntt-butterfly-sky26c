# test_mod_mult.py -- the pipelined Barrett multiplier.
#
# Two things are being checked, and they fail in different ways:
#
#   1. the arithmetic -- (a*b) mod q for field elements a, b
#   2. the pipeline -- exactly 3 clocks of latency, and results that stay in
#      order when operations are issued back to back
#
# The second is the one that pipelining introduces. A combinational block cannot
# get its results out of order or drop a valid; a three-stage one can, and the
# symptom would be a transform that is wrong by one butterfly's worth in a way
# that looks like an arithmetic bug.

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

from ntt_golden import Q, mod_mult, barrett_remainder

LATENCY = 3


async def reset(dut):
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_latency_is_three(dut):
    """out_valid must appear exactly 3 clocks after in_valid, every time."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    for a, b in [(0, 0), (1, 1), (Q - 1, Q - 1), (1729, 2580)]:
        dut.a.value = a
        dut.b.value = b
        dut.in_valid.value = 1
        await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        dut.a.value = 0
        dut.b.value = 0          # operands withdrawn: the pipeline holds its own state

        for n in range(1, LATENCY + 3):
            await ReadOnly()
            valid = int(dut.out_valid.value)
            got = int(dut.c.value)
            await NextTimeStep()
            if valid:
                assert n == LATENCY, f"latency was {n}, expected {LATENCY}"
                assert got == mod_mult(a, b), \
                    f"{a}*{b} mod q: got {got}, expected {mod_mult(a, b)}"
                break
            await RisingEdge(dut.clk)
        else:
            assert False, f"no result for {a}*{b}"
    dut._log.info(f"latency is exactly {LATENCY} clocks, and operands need not "
                  f"be held after in_valid")


@cocotb.test()
async def test_streaming(dut):
    """One multiply issued every clock for 2000 clocks. Results must come back
    in order, one per clock, three behind."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(90)
    ops = [(random.randrange(Q), random.randrange(Q)) for _ in range(2000)]
    # boundary cases at the front, where an off-by-one in the pipeline shows up
    ops[:4] = [(0, Q - 1), (Q - 1, 0), (Q - 1, Q - 1), (1, Q - 1)]

    got = []
    for i in range(len(ops) + LATENCY):
        if i < len(ops):
            dut.a.value = ops[i][0]
            dut.b.value = ops[i][1]
            dut.in_valid.value = 1
        else:
            dut.in_valid.value = 0
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.out_valid.value):
            got.append(int(dut.c.value))
        await NextTimeStep()

    assert len(got) == len(ops), f"got {len(got)} results for {len(ops)} operations"
    exp = [mod_mult(a, b) for a, b in ops]
    bad = [(i, got[i], exp[i]) for i in range(len(ops)) if got[i] != exp[i]]
    for i, g, e in bad[:8]:
        dut._log.error(f"op {i} {ops[i]}: got {g}, expected {e}")
    assert not bad, f"{len(bad)}/{len(ops)} streamed results wrong"
    dut._log.info(f"{len(ops)} multiplies issued one per clock, all correct and in order")


@cocotb.test()
async def test_barrett_bound(dut):
    """Two conditional subtracts are only enough because the remainder before
    them is under 3q.

    Estimating the quotient from the top of the product alone -- which is what
    halves the constant multiplier -- makes that remainder as large as 6935
    rather than the textbook form's 2q. Drive the products that push it hardest
    and require a fully reduced field element out."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    def pre_subtract_remainder(a, b):
        return barrett_remainder(a * b)

    # Search operand pairs directly rather than factoring a target product:
    # every (a, b) with a, b < q is reachable, so the worst remainder over a
    # wide sweep of pairs is the worst the hardware can ever be asked for.
    random.seed(95)
    pairs = [(a, b) for a in range(1, Q, 7)
             for b in (Q - 1, Q - 2, (a * 2) % Q or 1)]
    pairs += [(random.randrange(1, Q), random.randrange(1, Q)) for _ in range(4000)]
    cases = sorted(pairs, key=lambda ab: -pre_subtract_remainder(*ab))[:60]
    cases += [(Q - 1, Q - 1), (Q - 1, Q - 2), (1, Q - 1), (Q - 1, 1)]

    worst_r = max(pre_subtract_remainder(a, b) for a, b in cases)
    assert worst_r >= 2 * Q, \
        f"the search found no case needing BOTH subtracts (worst {worst_r})"

    for a, b in cases:
        dut.a.value = a
        dut.b.value = b
        dut.in_valid.value = 1
        await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        for _ in range(LATENCY - 1):
            await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.out_valid.value), "no result"
        got = int(dut.c.value)
        await NextTimeStep()
        assert got == (a * b) % Q, f"{a}*{b}: got {got}, expected {(a * b) % Q}"
        assert got < Q, f"{a}*{b} = {got} is not reduced"
    dut._log.info(f"{len(cases)} worst-case Barrett products, all fully reduced; "
                  f"largest pre-subtract remainder exercised was {worst_r} "
                  f"(3q = {3 * Q})")
