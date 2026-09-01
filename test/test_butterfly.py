# test_butterfly.py -- the shared five-operation datapath.
#
# One multiplier, one adder and two subtractors serve CT, GS, MUL, ZMUL and
# ADD, so the failure mode to hunt is cross-talk: a mux that leaks the forward
# transform's post-multiply subtract into the inverse's output, or an operand
# select that survives an op change. The tests therefore interleave the ops
# rather than running each in a clean block.
#
# a, b and zeta must hold steady from in_valid to out_valid -- the post-multiply
# adder and subtractor read them live instead of from a delay chain. That is
# part of the contract, and it is why the caller keeps them in registers.

import random
from collections import Counter

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

from ntt_golden import (Q, ZETAS, apply_op, OP_NAMES,
                        OP_CT, OP_GS, OP_MUL, OP_ZMUL, OP_ADD)

MUL_OPS = [OP_CT, OP_GS, OP_MUL, OP_ZMUL]
ALL_OPS = MUL_OPS + [OP_ADD]
LATENCY = 3


async def reset(dut):
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.op.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.zeta.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def outputs(dut):
    return int(dut.a_out.value), int(dut.b_out.value)


async def run_op(dut, op, a, b, zeta):
    """Issue one operation and return its result.

    ADD uses no multiply, so its outputs are combinational and live in the same
    cycle; out_valid never pulses for it. Everything else waits three clocks.
    """
    dut.op.value = op
    dut.a.value = a
    dut.b.value = b
    dut.zeta.value = zeta
    dut.in_valid.value = 1 if op != OP_ADD else 0
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0

    if op == OP_ADD:
        await ReadOnly()
        got = outputs(dut)
        await NextTimeStep()
        return got, 0

    n = 1
    while True:
        await ReadOnly()
        valid = int(dut.out_valid.value)
        got = outputs(dut)
        await NextTimeStep()
        if valid:
            return got, n
        assert n < 20, f"{OP_NAMES[op]} never produced a result"
        await RisingEdge(dut.clk)
        n += 1


@cocotb.test()
async def test_each_op(dut):
    """Each operation over random field elements, with its latency checked
    constant."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(91)
    for op in ALL_OPS:
        cases = [(0, 0, ZETAS[1]), (Q - 1, Q - 1, ZETAS[127]),
                 (0, Q - 1, ZETAS[64]), (Q - 1, 0, ZETAS[1])]
        cases += [(random.randrange(Q), random.randrange(Q), random.choice(ZETAS))
                  for _ in range(200)]
        seen = Counter()
        for a, b, z in cases:
            got, n = await run_op(dut, op, a, b, z)
            exp = apply_op(op, a, b, z)
            assert got == exp, \
                f"{OP_NAMES[op]}(a={a}, b={b}, zeta={z}): got {got}, expected {exp}"
            assert all(v < Q for v in got), f"{OP_NAMES[op]} produced a value >= q"
            seen[n] += 1
        assert len(seen) == 1, f"{OP_NAMES[op]}: variable latency {dict(seen)}"
        want = 0 if op == OP_ADD else LATENCY
        assert list(seen)[0] == want, \
            f"{OP_NAMES[op]} latency {list(seen)[0]}, expected {want}"
        dut._log.info(f"{OP_NAMES[op]:<5}: {len(cases)} operations correct, "
                      f"{list(seen)[0]} clocks each")


@cocotb.test()
async def test_op_interleaving(dut):
    """The five operations share one multiplier, one adder and two subtractors.
    Change the op every single operation, so any mux wired to the wrong source
    shows up immediately."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(92)
    for _ in range(600):
        op = random.choice(ALL_OPS)
        a, b = random.randrange(Q), random.randrange(Q)
        z = random.choice(ZETAS)
        got, _ = await run_op(dut, op, a, b, z)
        exp = apply_op(op, a, b, z)
        assert got == exp, \
            f"{OP_NAMES[op]}(a={a}, b={b}, zeta={z}): got {got}, expected {exp}"
    dut._log.info("600 operations with the op changing every time: no cross-talk")


@cocotb.test()
async def test_ct_gs_are_inverse(dut):
    """CT and GS must undo each other up to the factor of 2 that a single
    butterfly layer introduces -- checked against the hardware alone, with no
    reference to the Python model.

        CT: (a, b) -> (a + zb, a - zb)
        GS on that pair, same zeta: (2a, z(a - zb - a - zb)) = (2a, -2z^2 b)

    So the first output must be 2a mod q. That is a property of the two
    butterflies being genuine inverses of one another, and it is the reason one
    datapath can serve both transforms.
    """
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(93)
    for _ in range(200):
        a, b = random.randrange(Q), random.randrange(Q)
        z = random.choice(ZETAS)
        (x, y), _ = await run_op(dut, OP_CT, a, b, z)
        (p, _unused), _ = await run_op(dut, OP_GS, x, y, z)
        assert p == (2 * a) % Q, \
            f"GS(CT(a={a}, b={b}, z={z}))[0] = {p}, expected {(2 * a) % Q}"
    dut._log.info("GS undoes CT: the first output is 2a for 200 random inputs")


@cocotb.test()
async def test_mul_ignores_zeta_and_zmul_ignores_b(dut):
    """MUL is a*b and must not see the twiddle; ZMUL is z*a and must not see b.
    These are the two operand multiplexers that would silently corrupt basemul,
    and a wrong one still produces a plausible-looking field element."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(94)
    for _ in range(100):
        a, b = random.randrange(Q), random.randrange(Q)

        seen = set()
        for z in (0, 1, ZETAS[1], ZETAS[127], Q - 1):
            got, _ = await run_op(dut, OP_MUL, a, b, z)
            seen.add(got[0])
        assert len(seen) == 1, f"MUL({a},{b}) depends on zeta: {seen}"
        assert seen.pop() == (a * b) % Q

        z = random.choice(ZETAS)
        seen = set()
        for bb in (0, 1, Q - 1, random.randrange(Q)):
            got, _ = await run_op(dut, OP_ZMUL, a, bb, z)
            seen.add(got[0])
        assert len(seen) == 1, f"ZMUL({a},z={z}) depends on b: {seen}"
        assert seen.pop() == (z * a) % Q
    dut._log.info("MUL ignores zeta and ZMUL ignores b, over 100 random cases each")


@cocotb.test()
async def test_outputs_mirror_where_they_should(dut):
    """MUL and ZMUL return one value on both outputs; CT, GS and ADD return two
    genuinely different ones. Getting this wrong makes a host read garbage out
    of b_out and only notice several butterflies later."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(95)
    for _ in range(150):
        a, b = random.randrange(1, Q), random.randrange(1, Q)
        z = random.choice(ZETAS[1:])
        for op in (OP_MUL, OP_ZMUL):
            (x, y), _ = await run_op(dut, op, a, b, z)
            assert x == y, f"{OP_NAMES[op]} outputs should mirror: {x} vs {y}"
        for op in (OP_CT, OP_GS, OP_ADD):
            got, _ = await run_op(dut, op, a, b, z)
            assert got == apply_op(op, a, b, z)
    dut._log.info("MUL and ZMUL mirror; CT, GS and ADD carry two distinct results")
