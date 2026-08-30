# test.py -- Tiny Tapeout wrapper test for the NTT butterfly co-processor.
#
# Everything here drives the design through the physical TT pins only, so it
# runs unchanged against the RTL and against the post-layout gate-level netlist
# (make -B GATES=yes).
#
# Wire protocol (see src/bfu_stream.v):
#   in  : 4 bytes on ui_in, strobed by uio_in[0]   -> a, b, twiddle index k
#   out : 3 bytes on uo_out, strobed by uio_out[1] -> a_out, b_out

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly, NextTimeStep

from ntt_golden import ntt, ZETAS

Q = 3329

IN_VALID_BIT = 0        # uio_in[0]
OUT_VALID_BIT = 1       # uio_out[1]
BUSY_BIT = 2            # uio_out[2]


def pin(sig, bit):
    """One bit of a bus, treating X/Z as 0 (gate-level nets are X before reset)."""
    v = sig.value
    return 0 if not v.is_resolvable else (int(v) >> bit) & 1


def bus(sig):
    """Whole bus as an int, treating an unresolvable value as 0."""
    v = sig.value
    return 0 if not v.is_resolvable else int(v)


def encode(a, b, k):
    """Pack one butterfly into its 4-byte input frame."""
    return [a & 0xFF,
            ((b & 0x0F) << 4) | ((a >> 8) & 0x0F),
            (b >> 4) & 0xFF,
            k & 0x7F]


def decode(r0, r1, r2):
    """Unpack a 3-byte output frame."""
    a_out = r0 | ((r1 & 0x0F) << 8)
    b_out = ((r1 >> 4) & 0x0F) | (r2 << 4)
    return a_out, b_out


def golden(a, b, k):
    t = (ZETAS[k] * b) % Q
    return (a + t) % Q, (a - t) % Q


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def run_butterflies(dut, ops):
    """Stream (a, b, k) triples through the pins and return [(a_out, b_out)]."""
    in_bytes = []
    for a, b, k in ops:
        in_bytes += encode(a, b, k)

    out_bytes = []
    needed = 3 * len(ops)
    i = 0
    guard = 0
    limit = 8 * len(in_bytes) + 200

    while len(out_bytes) < needed:
        if i < len(in_bytes):
            dut.ui_in.value = in_bytes[i]
            dut.uio_in.value = 1 << IN_VALID_BIT
            i += 1
        else:
            dut.ui_in.value = 0
            dut.uio_in.value = 0

        await RisingEdge(dut.clk)
        await ReadOnly()
        if pin(dut.uio_out, OUT_VALID_BIT):
            out_bytes.append(bus(dut.uo_out))
        await NextTimeStep()

        guard += 1
        assert guard < limit, (
            f"timeout: sent {i}/{len(in_bytes)} bytes, "
            f"got {len(out_bytes)}/{needed} result bytes")

    dut.ui_in.value = 0
    dut.uio_in.value = 0
    return [decode(*out_bytes[j:j + 3]) for j in range(0, len(out_bytes), 3)]


@cocotb.test()
async def test_single_butterfly(dut):
    """Directed cases through the pin protocol, including the field edges."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    cases = [(0, 0, 1), (1, 1, 1), (3328, 3328, 1), (100, 200, 64), (3328, 1, 127)]
    got = await run_butterflies(dut, cases)

    for (a, b, k), (ga, gb) in zip(cases, got):
        ea, eb = golden(a, b, k)
        assert (ga, gb) == (ea, eb), \
            f"a={a} b={b} k={k}: got ({ga},{gb}) expected ({ea},{eb})"
    dut._log.info(f"{len(cases)} directed butterflies correct through the pins")


@cocotb.test()
async def test_random_butterflies(dut):
    """A long random stream, to exercise the pipeline at its natural rate."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(3)
    cases = [(random.randrange(Q), random.randrange(Q), random.randrange(1, 128))
             for _ in range(300)]
    got = await run_butterflies(dut, cases)

    assert len(got) == len(cases)
    for (a, b, k), (ga, gb) in zip(cases, got):
        ea, eb = golden(a, b, k)
        assert (ga, gb) == (ea, eb), \
            f"a={a} b={b} k={k}: got ({ga},{gb}) expected ({ea},{eb})"
    dut._log.info(f"{len(cases)} random butterflies correct through the pins")


@cocotb.test()
async def test_full_ntt_through_pins(dut):
    """End-to-end: drive a complete 256-point ML-KEM forward NTT through the
    chip exactly the way the host FPGA will, and check the result against the
    golden model. This is the test that proves the part does its job."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    random.seed(4)
    coeffs = [random.randrange(Q) for _ in range(256)]

    f = list(coeffs)
    k = 1
    length = 128
    butterflies = 0
    while length >= 2:
        start = 0
        while start < 256:
            ops = [(f[j], f[j + length], k) for j in range(start, start + length)]
            res = await run_butterflies(dut, ops)
            for idx, j in enumerate(range(start, start + length)):
                f[j], f[j + length] = res[idx]
            butterflies += len(ops)
            k += 1
            start += 2 * length
        length //= 2

    assert butterflies == 896, f"expected 896 butterflies, ran {butterflies}"
    expected = ntt(coeffs)
    mismatches = [(i, f[i], expected[i]) for i in range(256) if f[i] != expected[i]]
    for i, got, exp in mismatches[:16]:
        dut._log.error(f"coefficient {i}: got {got}, expected {exp}")
    assert not mismatches, f"{len(mismatches)}/256 coefficients differ from golden"

    dut._log.info("full 256-point ML-KEM forward NTT through the pins: "
                  "all 256 coefficients match the golden model")


@cocotb.test()
async def test_uio_directions(dut):
    """uio_oe must expose exactly the two status outputs and nothing else."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    oe = dut.uio_oe.value
    assert oe.is_resolvable, f"uio_oe unresolvable: {oe}"
    assert int(oe) == 0b00000110, f"uio_oe should be 0b00000110, got {int(oe):#010b}"
    dut._log.info("uio_oe = 0b00000110: uio[1]=out_valid, uio[2]=busy, rest inputs")
