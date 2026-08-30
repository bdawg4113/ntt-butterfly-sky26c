# test_butterfly.py -- verifies the pipelined butterfly (src/butterfly.v).
#
# The butterfly has latency 4 and accepts a new operand set every clock, so the
# checker is a scoreboard: every cycle we drive in_valid we push the expected
# result, and every cycle out_valid comes back we pop and compare. That checks
# throughput, latency alignment and valid-tracking all at once, which a
# combinational "apply and settle" test cannot do.

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

Q = 3329
LATENCY = 4


def golden(a, b, zeta):
    t = (zeta * b) % Q
    return (a + t) % Q, (a - t) % Q


async def reset(dut):
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.zeta.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def run_stream(dut, stimulus, name):
    """Drive (a,b,zeta,valid) tuples one per clock and scoreboard the results."""
    expected = deque()
    got = 0

    # drive every cycle, then drain the pipeline with LATENCY idle cycles
    for item in list(stimulus) + [None] * (LATENCY + 2):
        if item is None:
            dut.in_valid.value = 0
        else:
            a, b, z = item
            dut.a.value = a
            dut.b.value = b
            dut.zeta.value = z
            dut.in_valid.value = 1
            expected.append((a, b, z) + golden(a, b, z))

        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.out_valid.value):
            assert expected, f"{name}: out_valid with nothing outstanding"
            a, b, z, exp_a, exp_b = expected.popleft()
            ga, gb = int(dut.a_out.value), int(dut.b_out.value)
            assert ga == exp_a, f"{name}: a_out a={a} b={b} z={z}: got {ga} exp {exp_a}"
            assert gb == exp_b, f"{name}: b_out a={a} b={b} z={z}: got {gb} exp {exp_b}"
            got += 1
        await NextTimeStep()

    dut.in_valid.value = 0
    assert not expected, f"{name}: {len(expected)} results never came out"
    return got


@cocotb.test()
async def test_butterfly_backtoback(dut):
    """Full-rate streaming: one butterfly issued every clock."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    random.seed(1)
    cases = [(0, 0, 1), (1, 1, 1), (3328, 3328, 1729), (100, 200, 17), (3328, 1, 3328)]
    cases += [(random.randrange(Q), random.randrange(Q), random.randrange(Q))
              for _ in range(4000)]

    n = await run_stream(dut, cases, "back-to-back")
    assert n == len(cases), f"expected {len(cases)} results, got {n}"
    dut._log.info(f"back-to-back: {n} butterflies, 1 per clock, all match golden")


@cocotb.test()
async def test_butterfly_bubbles(dut):
    """Randomly gapped in_valid: proves the valid pipeline tracks the data."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    random.seed(2)
    stimulus = []
    for _ in range(1500):
        if random.random() < 0.35:
            stimulus.append(None)          # bubble: in_valid low
        else:
            stimulus.append((random.randrange(Q), random.randrange(Q), random.randrange(Q)))

    live = [s for s in stimulus if s is not None]
    n = await run_stream(dut, stimulus, "bubbles")
    assert n == len(live), f"expected {len(live)} results, got {n}"
    dut._log.info(f"bubbles: {n} butterflies through a gapped stream, all match golden")


@cocotb.test()
async def test_butterfly_reset_clears_valid(dut):
    """Reset mid-flight must drop in-flight results, not emit stale ones."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    # push two operand sets in, then reset before they can emerge
    for _ in range(2):
        dut.a.value = 123
        dut.b.value = 456
        dut.zeta.value = 789
        dut.in_valid.value = 1
        await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    for _ in range(LATENCY + 2):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.out_valid.value) == 0, "stale result escaped after reset"
        await NextTimeStep()
    dut._log.info("reset correctly flushed the in-flight butterflies")
