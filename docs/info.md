<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This chip is the **modular arithmetic engine** of the Number Theoretic Transform used by **ML-KEM-512**
(FIPS 203, formerly Kyber), and it carries the **twiddle table on die**. It performs the forward transform's
butterflies, the inverse transform's butterflies, and the multiply-and-reduce operations the rest of a
polynomial multiplication is built from.

A host — an **Arty A7 FPGA** — holds the 256-coefficient polynomial and walks the address pattern. The chip
does the arithmetic and looks up its own constants: the host sends a twiddle **index**, never a value.

All values are **unsigned field elements in [0, q)** carried as 12 bits, with **q = 3329**.

### What is on chip, and what is not

The twiddle table is 128 entries of 12 bits — **467 cells**. It removes a table from the host's memory map and
turns each per-block twiddle write into a single index byte. Constants belong on chip.

The polynomial does not, and that is arithmetic rather than effort. 256 coefficients of 12 bits is **3,072
flip-flops**, about 80,800 µm² as enable flops — **222% of a 1x2 tile's 36,347 µm² of die**, before a single
read multiplexer, write decoder or gate of logic. A build that held the array on chip measured 24,706 cells
with the memory accounting for 21,248 of them, 86% of the design, and needed the largest tile Tiny Tapeout
offers. State that scales with the problem size stays with the host; constants do not.

### Modular reduction without a divider

Barrett reduction replaces the division in "mod q" with a multiply by a precomputed reciprocal and a shift.
The textbook form is

```
T   = a·b                    < q² = 11,082,241 < 2²⁴
quo = (T·μ) >> 24            μ = ⌊2²⁴/q⌋ = 5039
r   = T − quo·q              lands in [0, 2q)
c   = (r ≥ q) ? r − q : r
```

**The quotient estimate does not need all of T.** Shifting the product right first gives

```
quo = ((T >> 11)·μ) >> 13     same μ = 5039
```

which turns a **24×13 constant multiply into 13×13** — roughly half the gates in the most expensive stage.
Discarding the low 11 bits coarsens the estimate, so the remainder lands in `[0, 6936)` rather than `[0, 2q)`
and takes two conditional subtracts instead of one. That is a good trade: a 13-bit compare-and-subtract is a
few dozen cells, half a constant multiplier is several hundred. Measured, the change took `mod_mult` from
1,974 cells to **1,589**.

The bound is not an argument, it is a measurement. Over every one of the 11,082,241 reachable products the
largest remainder before the subtracts is **6935**. Two conditional subtracts always suffice (`6935 − 2q =
277`), and `6935 < 2¹³`, so the finishing datapath stays 13 bits wide — shifting one bit further would have
pushed the worst case to 8975 and cost a 14th bit everywhere downstream.

Only the low 13 bits of `T` and of `quo·q` are ever needed; they agree above bit 12 by construction, so the
subtraction cannot borrow out of that field. There is no 24-bit subtractor and no 26-bit product in the block.

### Why the multiplier is pipelined

Written combinationally, that expression chains **three multipliers** back to back: `a·b`, then `·μ`, then
`·q`. In sky130 that is on the order of 120 gate levels, or 12–18 ns at 0.1–0.15 ns per level. Against a 20 ns
period it is a margin of 1.1–1.6× — no margin at all once place-and-route adds wire delay, and exactly the
path that closes in synthesis and fails at the slow corner.

Three register stages put **one multiply in each**:

| stage | work |
| ----- | ---- |
| 1 | `t_hi ← (a·b) >> 11`, `t_lo ← (a·b)[12:0]` — one 12×12 |
| 2 | `quo ← (t_hi·μ) >> 13` — one 13×13 |
| 3 | `c ← finish(t_lo − (quo·q)[12:0])` — one 13×12 low half, then two conditional subtracts |

Latency is exactly 3 clocks, and it is free: the byte-serial pin interface cannot deliver operands anywhere
near one per clock, so a shorter pipeline would only idle.

### The two butterflies, and why the inverse is nearly free

```
Cooley-Tukey (forward)            Gentleman-Sande (inverse)
  t     = ζ·b mod q                 a_out = a + b     mod q
  a_out = a + t mod q               b_out = ζ·(b − a) mod q
  b_out = a − t mod q
  multiply then add/sub             subtract then multiply
```

These are the same three primitives in a different order. The only structural difference is that GS needs a
subtract **before** the multiplier where CT needs one **after** — so the inverse transform costs exactly one
extra `mod_sub` plus a few operand multiplexers. The multiplier, its pipeline, the ROM and the operand
registers are all shared. Adding the INTT does not add a second datapath; it rewires the one already there.

The forward transform walks the twiddle index **up** from 1; the inverse walks it **down** from 127.

Because the arithmetic is plain rather than Montgomery, **`INTT(NTT(f)) = f` exactly** — there is no residual
`R` to strip, so the host loses a whole 256-operation post-processing pass. (A Montgomery datapath returns
`f·R` and needs one.)

### Operating modes

`ctrl[2:0]` selects the operation:

| op | name | `a_out` | `b_out` | muls | used for |
| -- | ---- | ------- | ------- | ---- | -------- |
| 0 | CT | `a + ζ·b` | `a − ζ·b` | 1 | forward NTT |
| 1 | GS | `a + b` | `ζ·(b − a)` | 1 | inverse NTT |
| 2 | MUL | `a·b` | same | 1 | basemul, and the closing 1/n scale |
| 3 | ZMUL | `ζ·a` | same | 1 | basemul's twiddle multiply |
| 4 | ADD | `a + b` | `a − b` | 0 | polynomial add/subtract |

`ctrl[3]` is `zneg`, which selects `q − ζ` instead of `ζ`. **ZMUL and `zneg` together are what keep the
twiddle table on chip**: `basemul` multiplies modulo `x² − ζ` with the signed pair `±zetas[64+i]`, and without
them the host would have to hold the table after all, purely to supply that one constant. In this unsigned
representation the negative half is `q − ζ`, a 12-bit subtract rather than 128 more ROM words.

The inverse transform's closing scale is an ordinary `MUL` with `n⁻¹ mod q = 3303` as the `b` operand — one
constant is not worth a dedicated op when the host sequences everything anyway.

### Where the silicon goes

| block | cells |
| ----- | ----- |
| `butterfly` incl. `mod_mult` | 2,082 |
| `twiddle_rom` | 467 |
| `ntt_io` | 152 |
| **total** | **2,756** |

About 21,900 µm², or roughly **64% of a 1x2 tile's core** — against the 66.6% at which the previous 1x2 build
hardened with +6.2 ns of setup slack.

## How to test

Operands and results are wider than the pin budget, so the host assembles operands by **addressed byte
writes**, pulses `start`, then shifts the result back out.

### Writing operands

Put a byte on `ui_in[7:0]`, its register number on `uio_in[2:0]`, and raise `uio_in[3]` (`we`):

| addr | register | | addr | register |
| ---- | -------- | - | ---- | -------- |
| 0 | `a[7:0]` | | 4 | `k` = twiddle index `[6:0]` |
| 1 | `a[11:8]` | | 5 | `ctrl = { 4'b0, zneg, op[2:0] }` |
| 2 | `b[7:0]` | | 6, 7 | reserved |
| 3 | `b[11:8]` | | | |

Registers persist between operations, so a host walking one NTT block only rewrites the bytes that actually
changed — usually just the four operand bytes, since `k` and `ctrl` are constant across a whole block.

### Executing and reading back

A rising edge on `uio_in[4]` (`start`) launches the operation. `ADD` answers immediately; every other op takes
3 clocks. Three result bytes then appear on `uo_out[7:0]`, each qualified by `uio_out[5]` (`out_valid`), low
byte first, carrying `{ b_out[11:0], a_out[11:0] }`:

```
byte 0   a_out[7:0]
byte 1   { b_out[3:0], a_out[11:8] }
byte 2   b_out[11:4]
```

Two 12-bit results pack into three bytes exactly, so a butterfly costs three read cycles rather than the four
that two padded 16-bit values would.

`uio_out[6]` (`busy`) is high from launch until the last result byte has been presented. **Poll it rather than
counting clocks** — the latency is not the same for every op. **The operand registers must not be written
while `busy` is high**: the datapath reads them directly for the whole operation rather than taking its own
copy, which is part of how the design fits its tile.

### Running a transform

A full forward NTT is 7 layers of 128 Cooley-Tukey butterflies — **896 operations**, with the host supplying
the twiddle *index* per block. The inverse is 896 Gentleman-Sande butterflies with the index walking down,
followed by a 256-operation scaling pass by `n⁻¹ = 3303` in `MUL` mode. The round trip returns the original
polynomial exactly.

Polynomial multiplication is `INTT(basemul(NTT(a), NTT(b)))`. Each `basemul` is five multiplies and two adds
over a pair of degree-1 polynomials mod `x² − ζ`, which the host composes from `MUL`, `ZMUL` and `ADD` — with
both `ζ` and `−ζ` coming from the chip's own table.

### The tests

```sh
cd test
make                      # pin-level: all five ops, a full NTT, a round trip, basemul
make -f Makefile_bf       # the shared five-operation datapath
make -f Makefile_mult     # the three-stage pipelined Barrett multiplier
make -f Makefile_rom      # all 128 twiddle entries
python ntt_golden.py      # the model's own self-tests
```

`test.py` plays the part of the host FPGA: it holds the polynomial in Python, walks the FIPS 203 address
pattern, and streams every butterfly through the chip's pins. **Nowhere in it is a twiddle value written to
the chip** — `test_twiddle_rom_is_on_chip` reads all 128 back out by index through `ZMUL` with `a = 1`, which
is the test that could not have passed before the table moved on die.

Several checks avoid the golden model entirely, so a misreading of FIPS 203 cannot hide in model and hardware
together: `NTT(1)` must be `(1, 0)` at every one of the 128 quadratic factors (the CRT definition), `GS` must
undo `CT` to give `2a`, and each ROM entry is recomputed from `17^brv7(k) mod q` inside its own test.

## External hardware

An **FPGA or MCU** to hold the polynomial and drive the transform — for this project an **Arty A7-100T**.

Per butterfly the host reads `r[j]` and `r[j+len]`, writes the operand bytes that changed, pulses `start`, and
writes the two result halves back. It tracks the twiddle *index* `k`, which FIPS 203 already defines, and
never needs the table itself. A working reference implementation of exactly that sequencing is in
`test/test.py`.
