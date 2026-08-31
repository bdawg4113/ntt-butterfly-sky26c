# test_bfu.py -- the five-mode arithmetic core against the golden model.
#
# bfu_core has latency 5 and accepts one operation per clock, so every test
# streams operations and scoreboards the results. Mixed-mode streams matter
# especially: latency is uniform across modes precisely so results cannot
# reorder when the host switches mode mid-stream, and this checks that.

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

from ntt_golden import (Q, ZETAS, apply_mode, centre,
                        MODE_CT, MODE_GS, MODE_FQMUL, MODE_BARRETT, MODE_ADD)

LATENCY = 5
ALL_MODES = [MODE_CT, MODE_GS, MODE_FQMUL, MODE_BARRETT, MODE_ADD]
NAMES = {MODE_CT: "CT", MODE_GS: "GS", MODE_FQMUL: "FQMUL",
         MODE_BARRETT: "BARRETT", MODE_ADD: "ADD"}


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


async def reset(dut):
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.mode.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.zeta.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def run_ops(dut, ops, name):
    """ops: list of (mode, a, b, zeta) or None for a bubble."""
    pending = deque()
    seen = 0

    for op in list(ops) + [None] * (LATENCY + 2):
        if op is None:
            dut.in_valid.value = 0
        else:
            mode, a, b, z = op
            dut.mode.value = mode
            dut.a.value = a
            dut.b.value = b
            dut.zeta.value = z
            dut.in_valid.value = 1
            ea, eb = apply_mode(mode, a, b, z)
            pending.append((op, s16(ea), s16(eb)))

        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.out_valid.value):
            assert pending, f"{name}: result with nothing outstanding"
            op, ea, eb = pending.popleft()
            ga, gb = s16(int(dut.a_out.value)), s16(int(dut.b_out.value))
            m, a, b, z = op
            assert (ga, gb) == (ea, eb), (
                f"{name}: {NAMES[m]}(a={a}, b={b}, zeta={z}): "
                f"got ({ga}, {gb}) expected ({ea}, {eb})")
            seen += 1
        await NextTimeStep()

    dut.in_valid.value = 0
    assert not pending, f"{name}: {len(pending)} results never came out"
    return seen


@cocotb.test()
async def test_each_mode(dut):
    """Every mode on its own, over random operands in the ranges that occur."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(31)
    for mode in ALL_MODES:
        ops = [(mode, 0, 0, 1), (mode, 1, -1, ZETAS[1]), (mode, -3328, 3328, ZETAS[64])]
        ops += [(mode,
                 random.randrange(-18504, 18505),
                 random.randrange(-18504, 18505),
                 random.choice(ZETAS)) for _ in range(800)]
        n = await run_ops(dut, ops, NAMES[mode])
        assert n == len(ops)
        dut._log.info(f"{NAMES[mode]:<8}: {n} operations match the golden model")


@cocotb.test()
async def test_mixed_mode_stream(dut):
    """Modes interleaved at full rate -- results must not reorder."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(32)
    ops = [(random.choice(ALL_MODES),
            random.randrange(-18504, 18505),
            random.randrange(-18504, 18505),
            random.choice(ZETAS)) for _ in range(3000)]
    n = await run_ops(dut, ops, "mixed")
    assert n == len(ops)
    dut._log.info(f"mixed-mode stream: {n} operations, no reordering")


@cocotb.test()
async def test_bubbles(dut):
    """Randomly gapped in_valid, to prove the valid pipeline tracks the data."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(33)
    ops = []
    for _ in range(1500):
        if random.random() < 0.35:
            ops.append(None)
        else:
            ops.append((random.choice(ALL_MODES),
                        random.randrange(-3329, 3329),
                        random.randrange(-3329, 3329),
                        random.choice(ZETAS)))
    live = [o for o in ops if o is not None]
    n = await run_ops(dut, ops, "bubbles")
    assert n == len(live)
    dut._log.info(f"gapped stream: {n} operations, all correct")


@cocotb.test()
async def test_fqmul_gives_montgomery_reduce(dut):
    """MODE_FQMUL with b = 1 is a bare montgomery_reduce -- the operation the
    host uses to strip the residual R factor after a transform round trip."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(34)
    ops = [(MODE_FQMUL, random.randrange(-32768, 32768), 1, 0) for _ in range(500)]
    n = await run_ops(dut, ops, "mont")
    assert n == len(ops)
    dut._log.info(f"MODE_FQMUL(x, 1) == montgomery_reduce(x) over {n} values")
