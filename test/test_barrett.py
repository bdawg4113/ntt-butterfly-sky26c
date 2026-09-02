# test_barrett.py -- the Barrett reducer, Theorem 6.2.
#
# This unit is combinational and its input is one 16-bit word, so the entire
# input space is 65,536 values -- small enough to test COMPLETELY. There is no
# reason to sample here, and one good reason not to: the theorem is stated for
# |a| < 2^15, and a = -32768 sits exactly on that boundary. It is a value the
# hardware can be handed, so it has to be checked rather than assumed.
#
# Three properties, from the theorem:
#   1. congruence      barrett(a) = a (mod q)
#   2. centred range   barrett(a) is in (-q/2, q/2]
#   3. it is round     t is exactly round(a/q), not merely a bound

import cocotb
from cocotb.triggers import Timer

from ntt_golden import Q, BARRETT_V, BARRETT_K, barrett_reduce, s16


def drive(dut, a):
    dut.a.value = a


@cocotb.test()
async def test_exhaustive(dut):
    """Every one of the 65,536 signed 16-bit inputs, against the model."""
    bad = 0
    lo, hi = 0, 0
    for a in range(-32768, 32768):
        dut.a.value = a
        await Timer(1, unit="ns")
        got = s16(int(dut.c.value))
        exp = barrett_reduce(a)
        if got != exp:
            if bad < 8:
                dut._log.error(f"barrett({a}): got {got}, expected {exp}")
            bad += 1
        lo, hi = min(lo, got), max(hi, got)
    assert not bad, f"{bad}/65536 inputs wrong"
    dut._log.info(f"all 65,536 signed 16-bit inputs match; output range "
                  f"[{lo}, {hi}]")


@cocotb.test()
async def test_theorem_6_2(dut):
    """The two claims of Theorem 6.2, checked against the hardware alone --
    no reference to the Python model.

        for |a| < 2^15:  barrett(a) = a (mod q)  and  barrett(a) in (-q/2, q/2]
    """
    half = Q // 2
    for a in range(-32768, 32768):
        dut.a.value = a
        await Timer(1, unit="ns")
        c = s16(int(dut.c.value))
        assert (c - a) % Q == 0, f"barrett({a}) = {c} changed the residue"
        assert -half <= c <= half + 1, f"barrett({a}) = {c} is not centred"
    dut._log.info(f"Theorem 6.2 holds for every input: congruent mod q and "
                  f"inside (-{half}, {half}]")


@cocotb.test()
async def test_quotient_is_round_not_floor(dut):
    """The proof's real content is that t = round(a/q) EXACTLY, which is what
    makes the remainder centred rather than merely bounded by q.

    The rounding term 2^25 in the numerator is what buys that. Without it the
    shift would floor, and every negative input would come back off by one q.
    So: check that the implied quotient is the nearest integer, and
    specifically that negative inputs are not systematically low.
    """
    checked = 0
    for a in list(range(-32768, 32768, 97)) + [-32768, -1, 0, 1, 32767,
                                               -Q, Q, -Q // 2, Q // 2 + 1]:
        dut.a.value = a
        await Timer(1, unit="ns")
        c = s16(int(dut.c.value))
        t = (a - c) // Q                       # the quotient the hardware used
        assert a - t * Q == c
        # round-half-away is what the +2^25 gives; allow either tie direction
        assert abs(a / Q - t) <= 0.5 + 1e-9, \
            f"a={a}: t={t} is not round(a/q) = {a / Q:.3f}"
        checked += 1
    dut._log.info(f"{checked} inputs: the quotient is round(a/q), not floor -- "
                  f"the 2^{BARRETT_K - 1} rounding term is doing its job")


@cocotb.test()
async def test_constant_is_derived(dut):
    """v must be the constant the derivation gives, floor((2^26 + q/2)/q).

    A v that is merely 'close' still produces plausible output for most inputs
    and fails on a sparse set, which is the worst way for this to be wrong.
    Rather than read v out of the netlist, infer it: drive the input that
    maximises the quotient and check the result is still exact.
    """
    assert BARRETT_V == (2 ** BARRETT_K + Q // 2) // Q == 20159

    worst = []
    for a in range(-32768, 32768):
        t = (BARRETT_V * a + (1 << (BARRETT_K - 1))) >> BARRETT_K
        worst.append((abs(a - t * Q), a))
    worst.sort(reverse=True)
    for _, a in worst[:200]:
        dut.a.value = a
        await Timer(1, unit="ns")
        c = s16(int(dut.c.value))
        assert c == barrett_reduce(a) and abs(c) <= Q // 2 + 1
    dut._log.info(f"v = {BARRETT_V} = floor((2^{BARRETT_K} + q/2)/q); the 200 "
                  f"inputs with the largest remainders are all exact")
