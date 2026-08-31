<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This chip is the **modular arithmetic engine** of the Number Theoretic Transform used by **ML-KEM-512**
(FIPS 203, formerly Kyber). It performs the forward transform's butterflies, the inverse transform's
butterflies, and the modular multiply-and-reduce operations that the rest of a polynomial multiplication is
built from.

A host — an **Arty A7 FPGA** — holds the 256-coefficient polynomial and walks the address pattern. The chip
does the arithmetic. That split is deliberate: the arithmetic is the expensive part, while the coefficient
array as flip-flops would be over 8,000 registers, which is more silicon than the largest Tiny Tapeout tile.

All values are **signed 16-bit** and centred; the modulus is **q = 3329** and the Montgomery radix is
**R = 2^16**.

### The two reduction kernels

Every butterfly needs a multiply *and* a reduction mod q, and a hardware divider is out of the question. Two
classic tricks replace the division with multiplies and shifts.

**Montgomery reduction** takes a signed 32-bit product and returns `a·R⁻¹ mod q` with `|t| < q`:

```
m = (a mod 2^16) · QINV        QINV = q^-1 mod 2^16 = -3327
t = (a - m·q) >> 16            arithmetic shift
```

`m` is chosen precisely so that `m·q` matches `a` in the low 16 bits, which makes the shift exact. That also
means the subtraction cannot borrow out of those bits, so in hardware it collapses to a **16-bit** subtract
of the two top halves — no 32-bit subtractor is needed.

**Range reduction without a Barrett unit.** The inverse transform needs to pull running sums back into
range. Rather than build a dedicated Barrett reducer, the design reuses the multiplier: `fqmul(x, R mod q)`
is `x·R·R⁻¹ = x`, and Montgomery guarantees `|t| < q`, so it returns a centred representative without
changing the residue — exactly what Barrett was for. Folding it onto the shared multiplier removed a whole
arithmetic unit worth 6,304 µm², a sixth of the area budget.

The workhorse multiply is `fqmul(a,b) = montgomery_reduce(a·b)` — one 16×16 product into one Montgomery
reduction. The **twiddle factors are supplied pre-multiplied by R** (Montgomery form), so a butterfly multiply
`fqmul(ζ·R, x) = ζ·R·x·R⁻¹ = ζ·x` lands with no stray Montgomery factor. The host holds that table — it is
bit-identical to the reference Kyber `zetas` array, beginning `-1044, -758, -359, -1517, …`. There is no
on-chip ROM: the FPGA already has the values, and sending ζ directly is what `basemul` needs anyway, since
its twiddles are the signed pair `±zetas[64+i]`.

### The two butterflies

```
Cooley-Tukey (forward)            Gentleman-Sande (inverse)
  t     = fqmul(ζ, b)               a_out = reduce(a + b)
  a_out = a + t                     b_out = fqmul(ζ, b - a)
  b_out = a - t
  multiply then add/sub             add/sub then multiply
```

These are the same primitive sequenced differently, which is why one arithmetic core serves both transforms.
The forward transform walks the twiddle index **up** from 1; the inverse walks it **down** from 127.

### Why the multiplier is serial

A parallel 16×16 multiplier array costs 10,875 µm² — most of a 1x2 tile's usable area on its own. This design
forms the product one partial product per clock instead, using a 16-bit adder and a shift register: about 17
clocks per multiply, but a fraction of the silicon.

That costs nothing real, because **the accelerator is I/O-bound, not compute-bound**. Assembling a 48-bit
operand vector over an 8-bit bus already takes several clocks, so a one-per-clock datapath would simply sit
idle waiting for operands. Being multi-cycle also means the operands stay put in their registers for the
whole operation, so there is no pipeline bypass chain and no valid pipeline to keep in step — an entire
class of structure, and its bugs, disappears.

### Operating modes

`ctrl[2:0]` selects the operation:

| mode | name | `a_out` | `b_out` | used for |
| ---- | ---- | ------- | ------- | -------- |
| 000 | CT | `a + fqmul(ζ,b)` | `a - fqmul(ζ,b)` | forward NTT |
| 001 | GS | `reduce(a + b)` | `fqmul(ζ, b - a)` | inverse NTT |
| 010 | FQMUL | `fqmul(a, b)` | same | scaling, basemul |
| 011 | REDUCE | `reduce(a)` | same | range control |
| 100 | ADD | `a + b` | `a - b` | polynomial add/sub |

`FQMUL` with `b = 1` is a bare `montgomery_reduce`, which is how the host strips the residual Montgomery
factor after a round trip.

## How to test

Operands are 48 bits wide (`a`, `b`, `ζ`) and results 32 bits, both far wider than the pin budget, so the
host assembles operands by **addressed byte writes**, pulses `start`, then shifts the result back out.

### Writing operands

Put a byte on `ui_in[7:0]`, its register number on `uio_in[2:0]`, and raise `uio_in[3]` (`we`):

| addr | register | | addr | register |
| ---- | -------- | - | ---- | -------- |
| 0 | `a[7:0]` | | 4 | `zeta[7:0]` |
| 1 | `a[15:8]` | | 5 | `zeta[15:8]` |
| 2 | `b[7:0]` | | 6 | `ctrl = {5'b0, mode[2:0]}` |
| 3 | `b[15:8]` | | 7 | reserved |

Registers persist between operations, so a host walking one NTT layer only rewrites the bytes that actually
changed — usually just the four operand bytes, since ζ and the mode are constant across a whole layer.

### Executing and reading back

A rising edge on `uio_in[4]` (`start`) launches the operation. Operations are **multi-cycle**: 20 clocks for
`CT`, `FQMUL` and `REDUCE`, 39 for `GS` (which needs two multiplies), and 1 for `ADD`. Four result bytes then
appear on `uo_out[7:0]`, each qualified by `uio_out[5]` (`out_valid`), low byte first:

```
a_out[7:0]   a_out[15:8]   b_out[7:0]   b_out[15:8]
```

`uio_out[6]` (`busy`) is high from launch until the last result byte has been presented. Poll it rather than
counting clocks, since the operation length depends on the mode. **The operand registers must not be written
while `busy` is high** — the core reads them directly for the whole operation instead of taking its own copy,
which is part of how the design fits its tile.

### Running a transform

A full forward NTT is 7 layers of 128 Cooley-Tukey butterflies — **896 operations**, the host supplying the
twiddle value per block. The inverse is 896 Gentleman-Sande butterflies with the index walking down, followed
by a 256-operation scaling pass by `f = R²/128 mod q = 1441` in `FQMUL` mode.

The round trip leaves one extra Montgomery factor: `INTT(NTT(f)) ≡ f·R (mod q)`. One `FQMUL(x, 1)` per
coefficient removes it.

Polynomial multiplication is `INTT(basemul(NTT(a), NTT(b)))`. Each `basemul` is five `fqmul`s and two adds
over a pair of degree-1 polynomials mod `x² - ζ`, which the host composes from `FQMUL` and `ADD` operations.

### The tests

```sh
cd test
make                      # pin-level: all modes, a full NTT, and an NTT->INTT round trip
make -f Makefile_bfu      # the five-mode arithmetic core
make -f Makefile_serfq    # the serial Montgomery multiply
```

`test.py` plays the part of the host FPGA: it holds the polynomial in Python, walks the FIPS 203 address
pattern, and streams every butterfly through the chip's pins — then checks all 256 coefficients against
`ntt_golden.py`, a bit-exact model whose constants are verified against the reference Kyber tables.

## External hardware

An **FPGA or MCU** to hold the polynomial and drive the transform — for this project an **Arty A7-100T**.

Per butterfly the host reads `r[j]` and `r[j+len]`, writes the operand bytes that changed, pulses `start`,
and writes the two result halves back to the same addresses. The address walk is the standard FIPS 203
Algorithm 9 (forward) and Algorithm 10 (inverse) loop; a working reference implementation of exactly that
sequencing is in `test/test.py`.
