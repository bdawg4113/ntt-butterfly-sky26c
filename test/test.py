# test.py -- Tiny Tapeout wrapper test for the ML-KEM NTT/INTT accelerator.
#
# Everything here drives the design through the physical TT pins only, so it
# runs unchanged against the RTL and against the post-layout gate-level netlist
# (make -B GATES=yes).
#
# The chip is the arithmetic engine of the transform. These tests play the part
# of the host FPGA: they hold the 256-coefficient polynomial in Python, walk the
# FIPS 203 address pattern, and stream each butterfly's operands through the
# chip -- which is exactly what the Arty A7 will do.
#
# Pin protocol (see src/bfu_io.v):
#   ui_in[7:0]   write data       uio_in[2:0] register address
#   uio_in[3]    write enable     uio_in[4]   start (rising edge)
#   uo_out[7:0]  result byte      uio_out[5]  out_valid    uio_out[6] busy

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly, NextTimeStep

from ntt_golden import (Q, R_MOD_Q, ZETAS, F, s16, centre,
                        ntt, invntt, apply_mode, montgomery_reduce,
                        MODE_CT, MODE_GS, MODE_FQMUL, MODE_BARRETT, MODE_ADD)

# register map
A_LO, A_HI, B_LO, B_HI, Z_LO, Z_HI, CTRL = range(7)

WE_BIT, START_BIT = 3, 4
OUT_VALID_BIT, BUSY_BIT = 5, 6

ZETA_FROM_ROM = 1 << 3          # ctrl bit 3


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
        """Pulse start and collect the four result bytes."""
        d = self.dut
        d.uio_in.value = 1 << START_BIT
        await RisingEdge(d.clk)
        d.uio_in.value = 0

        out = []
        guard = 0
        while len(out) < 4:
            await RisingEdge(d.clk)
            await ReadOnly()
            if pin(d.uio_out, OUT_VALID_BIT):
                out.append(bus(d.uo_out))
            await NextTimeStep()
            guard += 1
            assert guard < 64, f"timed out with {len(out)}/4 result bytes"

        a_out = s16(out[0] | (out[1] << 8))
        b_out = s16(out[2] | (out[3] << 8))
        return a_out, b_out

    async def op(self, mode, a, b, zeta=None, k=None):
        """One operation. Pass zeta for a literal twiddle, or k for a ROM index."""
        a &= 0xFFFF
        b &= 0xFFFF
        await self.write(A_LO, a)
        await self.write(A_HI, a >> 8)
        await self.write(B_LO, b)
        await self.write(B_HI, b >> 8)
        if k is not None:
            await self.write(Z_LO, k)
            await self.write(Z_HI, 0)
            await self.write(CTRL, mode | ZETA_FROM_ROM)
        else:
            z = (zeta or 0) & 0xFFFF
            await self.write(Z_LO, z)
            await self.write(Z_HI, z >> 8)
            await self.write(CTRL, mode)
        return await self.execute()


@cocotb.test()
async def test_modes_through_pins(cocotb_dut):
    """Every mode, driven through the register interface."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    random.seed(41)
    checked = 0
    for mode in (MODE_CT, MODE_GS, MODE_FQMUL, MODE_BARRETT, MODE_ADD):
        for _ in range(12):
            a = random.randrange(-3329, 3329)
            b = random.randrange(-3329, 3329)
            z = random.choice(ZETAS)
            got = await acc.op(mode, a, b, zeta=z)
            exp = tuple(s16(v) for v in apply_mode(mode, a, b, z))
            assert got == exp, f"mode {mode} (a={a},b={b},z={z}): got {got} exp {exp}"
            checked += 1
    dut._log.info(f"{checked} operations across all five modes correct via the pins")


@cocotb.test()
async def test_rom_twiddles(cocotb_dut):
    """ctrl bit 3 selects the on-chip twiddle ROM; check it against the table."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    for k in (0, 1, 2, 63, 64, 126, 127):
        # MODE_CT with a = 0 returns (+t, -t) where t = fqmul(zetas[k], b)
        a, b = 0, 1000
        got = await acc.op(MODE_CT, a, b, k=k)
        exp = tuple(s16(v) for v in apply_mode(MODE_CT, a, b, ZETAS[k]))
        assert got == exp, f"ROM[{k}]: got {got} expected {exp}"
    dut._log.info("on-chip twiddle ROM matches the Montgomery-form table")


async def host_ntt(acc, coeffs):
    """Forward NTT, sequenced by the host exactly as the FPGA will."""
    r = list(coeffs)
    k = 1
    length = 128
    while length >= 2:
        start = 0
        while start < 256:
            for j in range(start, start + length):
                a, b = await acc.op(MODE_CT, r[j], r[j + length], k=k)
                r[j], r[j + length] = a, b
            k += 1
            start += 2 * length
        length >>= 1
    return r


async def host_invntt(acc, coeffs):
    """Inverse NTT, then the final scale by f = 1441."""
    r = list(coeffs)
    k = 127
    length = 2
    while length <= 128:
        start = 0
        while start < 256:
            for j in range(start, start + length):
                a, b = await acc.op(MODE_GS, r[j], r[j + length], k=k)
                r[j], r[j + length] = a, b
            k -= 1
            start += 2 * length
        length <<= 1
    # 256-cycle scaling pass: every coefficient times f, via MODE_FQMUL
    return [(await acc.op(MODE_FQMUL, x, F))[0] for x in r]


@cocotb.test()
async def test_forward_ntt(cocotb_dut):
    """A complete 256-point forward NTT driven through the pins."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    random.seed(42)
    v = [centre(random.randrange(Q)) for _ in range(256)]
    got = await host_ntt(acc, v)
    exp = ntt(v)
    bad = [(i, got[i], exp[i]) for i in range(256) if got[i] != exp[i]]
    for i, g, e in bad[:8]:
        dut._log.error(f"coefficient {i}: got {g}, expected {e}")
    assert not bad, f"{len(bad)}/256 coefficients differ from the golden model"
    dut._log.info("forward NTT: 896 butterflies, all 256 coefficients match")


@cocotb.test()
async def test_ntt_intt_round_trip(cocotb_dut):
    """NTT then INTT through the pins must return f*R, per Eq (10.4), and a
    single montgomery_reduce must then recover the original polynomial."""
    dut = cocotb_dut
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    acc = Accel(dut)
    await acc.reset()

    random.seed(43)
    v = [centre(random.randrange(Q)) for _ in range(256)]

    fwd = await host_ntt(acc, v)
    assert fwd == ntt(v), "forward transform diverged"

    inv = await host_invntt(acc, fwd)
    assert inv == invntt(fwd), "inverse transform diverged"

    # Eq (10.4): the round trip leaves one extra Montgomery factor R
    assert all((inv[i] - v[i] * R_MOD_Q) % Q == 0 for i in range(256)), \
        "round trip is not f*R mod q"

    # strip it with one MODE_FQMUL(x, 1), i.e. a bare montgomery_reduce
    recovered = [(await acc.op(MODE_FQMUL, x, 1))[0] for x in inv]
    assert all((recovered[i] - v[i]) % Q == 0 for i in range(256)), \
        "montgomery_reduce did not recover the original coefficients"

    dut._log.info("NTT -> INTT round trip through the pins recovers all 256 "
                  "coefficients (Eq 10.4, then one montgomery_reduce)")


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
