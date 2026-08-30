<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This is a hardware accelerator for the inner loop of the **Number Theoretic Transform (NTT)** used by
**ML-KEM** (FIPS 203, formerly Kyber). The NTT is what makes polynomial multiplication in ML-KEM fast, and
its inner loop is the Cooley-Tukey *butterfly*, which the chip computes in the field GF(q) with **q = 3329**:

```
t     = zeta * b  mod q      (twiddle multiply)
a_out = a + t     mod q      -> f[j]
b_out = a - t     mod q      -> f[j+len]
```

A full 256-point forward NTT is 7 stages of 128 butterflies each, 896 in total. The chip computes the
butterflies; the host walks the address pattern and holds the polynomial.

### The modular multiplier

The hard part is `zeta * b mod q` without a divider. The design uses **Barrett reduction** with
`k = 24` and `mu = floor(2^24 / q) = 5039`:

```
T   = a * b                  (< 3329^2, fits in 24 bits)
quo = (T * mu) >> 24         (quotient estimate)
r   = T - quo*q
c   = (r >= q) ? r - q : r   (a single conditional subtraction)
```

That a *single* conditional subtraction is enough was checked exhaustively over all 11,075,585 possible
products: the largest `r` that occurs is **4903**, which is below `2q = 6658`. It also stays under 8192,
so the subtraction can be evaluated in 13 bits without losing a live bit.

### Why it is pipelined

Written combinationally, that multiplier chains **three** multipliers back to back (`a*b`, then `T*mu`,
then `quo*q`) and measures **92 logic levels** — far too deep to close timing. Each multiply now gets its
own pipeline stage, cutting the critical path to about **50 levels**:

| Stage | Work | Levels |
| ----- | ---- | ------ |
| 1 | `T = a * b` | 45 |
| 2 | `quo = (T * mu) >> 24` | 53 |
| 3 | `r = T - quo*q`, conditional subtract | 36 |
| 4 | `mod_add` / `mod_sub` | 32 |

The result is a **4-cycle latency, one-butterfly-per-clock** datapath. `a` bypasses the multiplier, so it
is delayed through a 3-deep shift register to meet `t` at the adder stage.

The twiddle factors live in an on-chip ROM (all 127 values of `zeta^bitrev7(k) mod q`), so the host sends a
7-bit index rather than a 12-bit constant — which is what lets an operand set fit in 4 bytes instead of 5.

## How to test

Tiny Tapeout's 8-bit ports are too narrow for a butterfly's operands, so operands arrive as a **4-byte
frame** and results leave as a **3-byte frame**, one byte per clock.

### Sending an operand set

Put each byte on `ui_in[7:0]` and raise `uio_in[0]` (`in_valid`) for that clock:

| Byte | `ui_in[7:0]` |
| ---- | ------------ |
| 0 | `a[7:0]` |
| 1 | `b[3:0]`, `a[11:8]` |
| 2 | `b[11:4]` |
| 3 | `0`, `k[6:0]` (twiddle index, 1..127) |

The 4th byte completes the frame and starts the butterfly.

### Receiving a result

Four clocks later the result appears on `uo_out[7:0]`, one byte per clock, each qualified by
`uio_out[1]` (`out_valid`):

| Byte | `uo_out[7:0]` |
| ---- | ------------- |
| 0 | `a_out[7:0]` |
| 1 | `b_out[3:0]`, `a_out[11:8]` |
| 2 | `b_out[11:4]` |

`uio_out[2]` (`busy`) is high while a butterfly is in flight or a result is being emitted.

### Flow control

None is needed. The input bus carries at most one byte per clock, so a butterfly can be issued at most
once every 4 clocks; a result takes 3 clocks to emit and therefore always finishes before the next one
arrives. Just stream bytes in and latch bytes out.

At 50 MHz this is one butterfly every 80 ns, so a complete 256-point forward NTT (896 butterflies) takes
roughly **72 microseconds**, host sequencing aside.

### Running the tests

```sh
cd test
make            # wrapper tests through the pins, incl. a full 256-point NTT
make -f Makefile_bf    # the pipelined butterfly on its own
make -f Makefile_rom   # every entry of the twiddle ROM
make -f Makefile_top   # reference NTT sequencer vs the Python golden model
```

`test/test.py` drives a complete ML-KEM forward NTT through the pins exactly the way an external host
would, and checks all 256 output coefficients against `test/ntt_golden.py`.

## External hardware

None is required to use the chip, but it is designed to be driven by an **FPGA or MCU** that holds the
256-coefficient polynomial and walks the NTT address pattern — for this project, an **Arty A7-100T**.

The host needs to do three things per butterfly: read `f[j]` and `f[j+len]`, send the 4-byte frame with
the stage's twiddle index `k`, and write the 3-byte result back to the same two addresses. The address
walk it must follow is the standard FIPS 203 Algorithm 9 loop, and a working reference implementation of
exactly that sequencing is in `test/test.py` (`test_full_ntt_through_pins`).

The coefficient array deliberately lives off-chip: as flip-flops a 256x12 array synthesises to over 6000
registers, which is more silicon than the largest Tiny Tapeout tile provides.
