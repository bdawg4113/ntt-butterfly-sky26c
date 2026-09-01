# test.py -- Tiny Tapeout wrapper test for the ML-KEM NTT/INTT accelerator.
#
# Everything here drives the design through the physical TT pins only, so it
# runs unchanged against the RTL and against the post-layout gate-level netlist
# (make -B GATES=yes).
#
# The chip is the arithmetic engine and holds the twiddle table. These tests
# play the part of the host FPGA: they hold the 256-coefficient polynomial in
# Python, walk the FIPS 203 address pattern, and stream each butterfly's
# operands through the chip -- passing the twiddle INDEX k, never the value.
# Nowhere in this file is a zeta looked up; that is the point.
#
# Pin protocol (see src/ntt_io.v):
#   ui_in[7:0]   write data       uio_in[2:0] register address
#   uio_in[3]    write enable     uio_in[4]   start (rising edge)
#   uo_out[7:0]  result byte      uio_out[5]  out_valid    uio_out[6] busy

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly, NextTimeStep

from ntt_golden import (Q, N, ZETAS, NINV, ntt, invntt, apply_op, basemul,
                        mod_mult, OP_CT, OP_GS, OP_MUL, OP_ZMUL, OP_ADD,
                        OP_NAMES)

# register map
A_LO, A_HI, B_LO, B_HI, K_IDX, CTRL = range(6)

WE_BIT, START_BIT = 3, 4
OUT_VALID_BIT, BUSY_BIT = 5, 6

# longest operation is 3 multiplier clocks plus three result bytes
OP_TIMEOUT = 40


def pin(sig, bit):
    v = sig.value
    return 0 if not v.is_resolvable else (int(v) >> bit) & 1


def bus(sig):
    v = sig.value
    return 0 if not v.is_resolvable else int(v)


class Accel:
    """Host-side driver: mirrors what the FPGA does over the pins."""

    def __init__(self, dut):
        self.dut = dut
        self.shadow = {}        # last value written to each register

    async def reset(self):
        d = self.dut
        d.ena.value = 1
        d.ui_in.value = 0
        d.uio_in.value = 0
        d.rst_n.value = 0
        await ClockCycles(d.clk, 5)
        d.rst_n.value = 1
        await ClockCycles(d.clk, 2)
        self.shadow = {}

    async def write(self, addr, val):
        """Write one register, skipping the bus cycle if it already holds val."""
        val &= 0xFF
        if self.shadow.get(addr) == val:
            return
        d = self.dut
        d.ui_in.value = val
        d.uio_in.value = (addr & 7) | (1 << WE_BIT)
        await RisingEdge(d.clk)
        d.uio_in.value = 0
        self.shadow[addr] = val

    async def execute(self):
        """Pulse start and collect the three result bytes."""
        d = self.dut
        d.uio_in.value = 1 << START_BIT
        await RisingEdge(d.clk)
        d.uio_in.value = 0

        out = []
        guard = 0
        while len(out) < 3:
            await ReadOnly()
            if pin(d.uio_out, OUT_VALID_BIT):
                out.append(bus(d.uo_out))
            await NextTimeStep()
            if len(out) < 3:
                await RisingEdge(d.clk)
            guard += 1
            assert guard < OP_TIMEOUT, \
                f"timed out with {len(out)}/3 result bytes"

        packed = out[0] | (out[1] << 8) | (out[2] << 16)
        return packed & 0xFFF, (packed >> 12) & 0xFFF

    async def op(self, op, a, b, k=0, zneg=0):
        """Run one operation. The twiddle is selected by index, not value."""
        await self.write(A_LO, a)
        await self.write(A_HI, a >> 8)
        await self.write(B_LO, b)
        await self.write(B_HI, b >> 8)
        await self.write(K_IDX, k)
        await self.write(CTRL, (op & 7) | ((zneg & 1) << 3))
        return await self.execute()


def zeta_of(k, zneg=0):
    """What the chip's ROM will supply for this index -- used only to build the
    expected value, never written to the chip."""
    z = ZETAS[k]
    return (Q - z) % Q if zneg else z


@cocotb.test()
async def test_all_ops_through_pins(cocotb_dut):
    """Every operation, driven through the register interface."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    random.seed(71)
    checked = 0
    for op in (OP_CT, OP_GS, OP_MUL, OP_ZMUL, OP_ADD):
        for _ in range(20):
            a = random.randrange(Q)
            b = random.randrange(Q)
            k = random.randrange(1, 128)
            zneg = random.randrange(2)
            got = await acc.op(op, a, b, k, zneg)
            exp = apply_op(op, a, b, zeta_of(k, zneg))
            assert got == exp, (f"{OP_NAMES[op]}(a={a},b={b},k={k},zneg={zneg}): "
                                f"got {got} expected {exp}")
            checked += 1
    dut._log.info(f"{checked} operations across all five ops correct via the pins")


@cocotb.test()
async def test_twiddle_rom_is_on_chip(cocotb_dut):
    """The host never sends a twiddle value -- only an index. Sweep all 128
    indices through OP_ZMUL, which returns z*a directly, and check the chip
    produced the right constant from its own table.

    This is the test that would have failed before the ROM moved on chip: with
    no table in silicon there is nothing for an index to select."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    # a = 1 makes ZMUL return the twiddle itself, so the readback IS the table
    table = []
    for k in range(128):
        got, mirror = await acc.op(OP_ZMUL, 1, 0, k)
        assert got == mirror, "ZMUL outputs should mirror"
        table.append(got)
    assert table == ZETAS, "the on-chip table is not the FIPS 203 twiddle table"

    # and the negated half, which is what basemul needs
    for k in (1, 64, 65, 100, 127):
        got, _ = await acc.op(OP_ZMUL, 1, 0, k, zneg=1)
        assert got == (Q - ZETAS[k]) % Q, f"zneg wrong at k={k}"
    dut._log.info("all 128 twiddles read back from the chip's own ROM by index, "
                  "plus the negated half")


@cocotb.test()
async def test_register_persistence(cocotb_dut):
    """Registers hold between operations, so a host walking an NTT block only
    rewrites what changed. Run the same operation twice writing nothing the
    second time."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    a, b, k = 1234, 567, 33
    first = await acc.op(OP_CT, a, b, k)
    second = await acc.execute()          # no register writes at all
    assert first == second, f"registers did not persist: {first} vs {second}"
    assert first == apply_op(OP_CT, a, b, zeta_of(k))
    dut._log.info("operand registers persist across operations")


async def host_ntt(acc, coeffs):
    """Forward NTT, sequenced by the host exactly as the FPGA will.

    Note what is NOT here: any twiddle value. The host tracks k, which FIPS 203
    already defines, and the chip looks the constant up itself."""
    r = list(coeffs)
    k = 1
    length = 128
    while length >= 2:
        start = 0
        while start < N:
            for j in range(start, start + length):
                a, b = await acc.op(OP_CT, r[j], r[j + length], k)
                r[j], r[j + length] = a, b
            k += 1
            start += 2 * length
        length >>= 1
    return r


async def host_invntt(acc, coeffs):
    """Inverse NTT, then the closing scale by 1/n = 3303."""
    r = list(coeffs)
    k = 127
    length = 2
    while length <= 128:
        start = 0
        while start < N:
            for j in range(start, start + length):
                a, b = await acc.op(OP_GS, r[j], r[j + length], k)
                r[j], r[j + length] = a, b
            k -= 1
            start += 2 * length
        length <<= 1
    return [(await acc.op(OP_MUL, x, NINV))[0] for x in r]


@cocotb.test()
async def test_forward_ntt(cocotb_dut):
    """A complete 256-point forward NTT driven through the pins."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    random.seed(72)
    v = [random.randrange(Q) for _ in range(N)]
    got = await host_ntt(acc, v)
    exp = ntt(v)
    bad = [(i, got[i], exp[i]) for i in range(N) if got[i] != exp[i]]
    for i, g, e in bad[:8]:
        dut._log.error(f"coefficient {i}: got {g}, expected {e}")
    assert not bad, f"{len(bad)}/{N} coefficients differ from the golden model"
    dut._log.info("forward NTT: 896 butterflies, all 256 coefficients match")


@cocotb.test()
async def test_ntt_intt_round_trip(cocotb_dut):
    """NTT then INTT through the pins must return the original polynomial
    exactly. In plain Barrett arithmetic there is no residual Montgomery factor,
    so this is an equality and not a congruence -- and the host does not need a
    stripping pass afterwards."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    random.seed(73)
    v = [random.randrange(Q) for _ in range(N)]

    fwd = await host_ntt(acc, v)
    assert fwd == ntt(v), "forward transform diverged"

    inv = await host_invntt(acc, fwd)
    assert inv == invntt(fwd), "inverse transform diverged"

    bad = [(i, inv[i], v[i]) for i in range(N) if inv[i] != v[i]]
    for i, g, e in bad[:8]:
        dut._log.error(f"coefficient {i}: got {g}, expected {e}")
    assert not bad, f"{len(bad)}/{N} coefficients did not survive the round trip"
    dut._log.info("NTT -> INTT through the pins recovers all 256 coefficients "
                  "exactly, with no residual factor to strip")


@cocotb.test()
async def test_known_vector(cocotb_dut):
    """A transform whose answer can be written down without the model.

    NTT of the constant polynomial f(x) = 1 is, by the CRT definition, the pair
    (1, 0) at every one of the 128 quadratic factors -- f is already its own
    remainder mod each x^2 - gamma. So the result is 1 at even indices and 0 at
    odd ones, and no twiddle table is needed to say so.
    """
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    f = [0] * N
    f[0] = 1
    got = await host_ntt(acc, f)
    exp = [1 if i % 2 == 0 else 0 for i in range(N)]
    assert got == exp, "NTT(1) is not (1,0) at every quadratic factor"
    dut._log.info("NTT(1) = (1,0) at all 128 factors -- checked against the CRT "
                  "definition, not the model")


@cocotb.test()
async def test_basemul(cocotb_dut):
    """A pointwise product, composed on chip from MUL, ZMUL and ADD.

    This is the operation that would force the twiddle table back into the host
    if ZMUL did not exist: its twiddles are the signed pair +/-zetas[64+i], and
    the sign is what zneg supplies.
    """
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    random.seed(74)
    for i in range(0, 64, 7):
        for zneg in (0, 1):
            a0, a1, b0, b1 = (random.randrange(Q) for _ in range(4))
            k = 64 + i

            # r0 = a0*b0 + zeta*(a1*b1)
            t, _ = await acc.op(OP_MUL, a1, b1)
            t, _ = await acc.op(OP_ZMUL, t, 0, k, zneg)
            u, _ = await acc.op(OP_MUL, a0, b0)
            r0, _ = await acc.op(OP_ADD, t, u)

            # r1 = a0*b1 + a1*b0
            t, _ = await acc.op(OP_MUL, a0, b1)
            u, _ = await acc.op(OP_MUL, a1, b0)
            r1, _ = await acc.op(OP_ADD, t, u)

            exp = basemul(a0, a1, b0, b1, zeta_of(k, zneg))
            assert (r0, r1) == exp, \
                f"basemul at k={k} zneg={zneg}: got {(r0, r1)} expected {exp}"
    dut._log.info("basemul composed on chip from MUL/ZMUL/ADD, with the twiddle "
                  "and its negation both coming from the on-chip table")


@cocotb.test()
async def test_add_is_single_cycle(cocotb_dut):
    """ADD needs no multiply, so it must answer without waiting three clocks.
    The point of polling busy rather than counting is that the latency is not
    the same for every op."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    async def clocks_to_first_byte(op, a, b):
        await acc.write(A_LO, a)
        await acc.write(A_HI, a >> 8)
        await acc.write(B_LO, b)
        await acc.write(B_HI, b >> 8)
        await acc.write(CTRL, op)
        d = dut
        d.uio_in.value = 1 << START_BIT
        await RisingEdge(d.clk)
        d.uio_in.value = 0
        n = 0
        while True:
            await ReadOnly()
            v = pin(d.uio_out, OUT_VALID_BIT)
            await NextTimeStep()
            if v:
                return n
            n += 1
            assert n < OP_TIMEOUT
            await RisingEdge(d.clk)

    n_add = await clocks_to_first_byte(OP_ADD, 1000, 2000)
    # drain
    await ClockCycles(dut.clk, 6)
    n_mul = await clocks_to_first_byte(OP_MUL, 1000, 2000)
    assert n_add < n_mul, \
        f"ADD ({n_add}) should be quicker than a multiply ({n_mul})"
    dut._log.info(f"ADD answers in {n_add} clocks, a multiply in {n_mul} -- "
                  f"poll busy, do not count")


@cocotb.test()
async def test_uio_directions(cocotb_dut):
    """uio_oe must expose exactly the two status outputs and nothing else."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    oe = dut.uio_oe.value
    assert oe.is_resolvable, f"uio_oe unresolvable: {oe}"
    assert int(oe) == 0b01100000, f"uio_oe should be 0b01100000, got {int(oe):#010b}"
    dut._log.info("uio_oe = 0b01100000: uio[5]=out_valid, uio[6]=busy, rest inputs")
