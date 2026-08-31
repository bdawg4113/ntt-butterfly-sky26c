# test_bfu.py -- the multi-cycle five-mode arithmetic core against the model.
#
# The core is multi-cycle rather than pipelined: it handles one operation at a
# time and raises busy while doing so, so these tests issue an operation, hold
# the operands steady, and wait for out_valid. Operand stability is part of the
# contract -- the core reads a, b and zeta directly for the whole operation
# rather than latching its own copies, which is where a chunk of the area
# saving came from.

import random
from collections import Counter

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

from ntt_golden import (Q, ZETAS, R_MOD_Q, apply_mode,
                        MODE_CT, MODE_GS, MODE_FQMUL, MODE_REDUCE, MODE_ADD)

ALL_MODES = [MODE_CT, MODE_GS, MODE_FQMUL, MODE_REDUCE, MODE_ADD]
NAMES = {MODE_CT: "CT", MODE_GS: "GS", MODE_FQMUL: "FQMUL",
         MODE_REDUCE: "REDUCE", MODE_ADD: "ADD"}


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


async def run_op(dut, mode, a, b, zeta):
    """Issue one operation and wait for its result. Returns (result, clocks)."""
    dut.mode.value = mode
    dut.a.value = a
    dut.b.value = b
    dut.zeta.value = zeta
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0          # operands stay driven, as the contract requires

    # out_valid is a one-clock pulse, and MODE_ADD needs no multiply so it
    # answers in the very next cycle -- sample before advancing, or the pulse
    # is stepped over.
    n = 1
    while True:
        await ReadOnly()
        valid = int(dut.out_valid.value)
        got = (s16(int(dut.a_out.value)), s16(int(dut.b_out.value)))
        await NextTimeStep()
        if valid:
            return got, n
        assert n < 100, f"{NAMES[mode]} never produced a result"
        await RisingEdge(dut.clk)
        n += 1


@cocotb.test()
async def test_each_mode(dut):
    """Every mode over random operands in the ranges that actually occur."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(61)
    timing = {}
    for mode in ALL_MODES:
        ops = [(0, 0, 1), (1, -1, ZETAS[1]), (-3328, 3328, ZETAS[64]),
               (16628, -16628, R_MOD_Q)]
        ops += [(random.randrange(-16628, 16629),
                 random.randrange(-16628, 16629),
                 random.choice(ZETAS)) for _ in range(150)]
        seen = Counter()
        for a, b, z in ops:
            got, n = await run_op(dut, mode, a, b, z)
            exp = tuple(s16(v) for v in apply_mode(mode, a, b, z))
            assert got == exp, \
                f"{NAMES[mode]}(a={a}, b={b}, zeta={z}): got {got}, expected {exp}"
            seen[n] += 1
        assert len(seen) == 1, f"{NAMES[mode]}: variable latency {dict(seen)}"
        timing[NAMES[mode]] = list(seen)[0]
        dut._log.info(f"{NAMES[mode]:<7}: {len(ops)} operations correct, "
                      f"{list(seen)[0]} clocks each")
    dut._log.info(f"latency by mode: {timing}")


@cocotb.test()
async def test_mode_switching(dut):
    """Modes interleaved one after another, to catch state left behind."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(62)
    for _ in range(400):
        mode = random.choice(ALL_MODES)
        a = random.randrange(-16628, 16629)
        b = random.randrange(-16628, 16629)
        z = random.choice(ZETAS)
        got, _ = await run_op(dut, mode, a, b, z)
        exp = tuple(s16(v) for v in apply_mode(mode, a, b, z))
        assert got == exp, \
            f"{NAMES[mode]}(a={a}, b={b}, zeta={z}): got {got}, expected {exp}"
    dut._log.info("400 operations with the mode changing every time: all correct")


@cocotb.test()
async def test_busy_protocol(dut):
    """busy must be high for the whole operation and low when idle, and
    in_valid must be ignored while busy."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    await ReadOnly()
    assert int(dut.busy.value) == 0, "busy should be low when idle"
    await NextTimeStep()

    # launch a GS operation (the longest, two multiplies) and poke in_valid
    # repeatedly while it runs; the result must be unaffected
    a, b, z = 1234, -5678, ZETAS[40]
    dut.mode.value = MODE_GS
    dut.a.value = a
    dut.b.value = b
    dut.zeta.value = z
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)

    n = 0
    busy_seen = 0
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        valid = int(dut.out_valid.value)
        busy_seen += int(dut.busy.value)
        got = (s16(int(dut.a_out.value)), s16(int(dut.b_out.value)))
        await NextTimeStep()
        n += 1
        if valid:
            break
        assert n < 100

    dut.in_valid.value = 0
    exp = tuple(s16(v) for v in apply_mode(MODE_GS, a, b, z))
    assert got == exp, f"GS corrupted by in_valid held high: got {got}, exp {exp}"
    assert busy_seen >= n - 1, "busy was not held for the whole operation"
    dut._log.info(f"busy held for {busy_seen}/{n} clocks; in_valid ignored while busy")


@cocotb.test()
async def test_reduce_replaces_barrett(dut):
    """MODE_REDUCE must return a centred representative of the same residue --
    the property the deleted Barrett unit used to provide."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(63)
    for _ in range(300):
        x = random.randrange(-32768, 32768)
        (got, mirror), _ = await run_op(dut, MODE_REDUCE, x, 0, 0)
        assert got == mirror, "MODE_REDUCE outputs should mirror"
        assert (got - x) % Q == 0, f"reduce({x}) changed the residue"
        assert abs(got) < Q, f"reduce({x}) = {got} is not centred"
    dut._log.info("MODE_REDUCE: 300 values congruent mod q and inside |t| < q")
