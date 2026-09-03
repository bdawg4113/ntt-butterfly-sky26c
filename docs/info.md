<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This chip is the **modular arithmetic engine** of the Number Theoretic Transform used by **ML-KEM-512**
(FIPS 203, formerly Kyber). It carries **both reduction kernels** — Montgomery and Barrett — and the
**128-entry twiddle table** on die.

A host — an **Arty A7 FPGA** — holds the 256-coefficient polynomial and walks the address pattern. The chip
does the arithmetic and looks up its own constants: the host sends a twiddle **index**, never a value.

All values are **signed 16-bit** and centred; the modulus is **q = 3329** and the Montgomery radix is
**R = 2¹⁶**.

### Both reductions, and the division of labour

Every butterfly needs a multiply *and* a reduction mod q, and a hardware divider is out of the question. Two
classic tricks replace the division with multiplies and shifts — and they are **not alternatives**. Each does
the job the other is bad at.

**Montgomery reduction** (Theorem 6.1) takes a signed 32-bit product and returns `a·R⁻¹ mod q` with `|t| < q`:

```
m = (a mod± R) · QINV        QINV = q⁻¹ mod 2¹⁶ = -3327
t = (a - m·q) / R
```

`m` is chosen precisely so that `m·q` matches `a` in the low 16 bits, which makes the division by R exact — a
wire, not a divider. It also means the subtraction cannot borrow out of those bits, so in hardware it collapses
to a **16-bit** subtract of the two top halves. No 32-bit subtractor exists on the die.

**Barrett reduction** (Theorem 6.2) takes a signed 16-bit value and returns a centred representative in
`(-q/2, q/2]`:

```
v = ⌊(2²⁶ + q/2)/q⌋ = 20159
t = ⌊(a·v + 2²⁵)/2²⁶⌋
barrett(a) = a - t·q
```

`v/2²⁶` approximates `1/q` closely enough that `t` is *exactly* `round(a/q)`, which is what makes the remainder
centred rather than merely bounded. The `2²⁵` term is what turns a floor into a round; without it every
negative input would come back one `q` low.

**Which goes where.** Montgomery runs after every *multiply*, because a multiply is where the R bookkeeping is
free: the twiddle carries a factor R, the product cancels it, and the reduction rides inside the multiplier's
own pipeline. Barrett runs after chains of *additions*, where no R factor is involved and the value simply
needs to come back into range. Gentleman-Sande adds `a` and `b` every layer with no multiply on that path, so
without a reducer the sum grows layer over layer until it overflows 16 bits.

That split is what makes the inverse transform cost **one** multiply per butterfly instead of two. Reusing
`fqmul(x, R mod q)` for range reduction is arithmetically sound and was what an earlier revision did — it
occupies the multiplier for a second pass on every GS butterfly. A dedicated Barrett unit buys that back.

### The Montgomery domain

Montgomery does not return `a mod q`; it returns `a·R⁻¹ mod q`. The fix (Key Idea 6.1) is to keep everything in
the **Montgomery domain**: the twiddle table is stored pre-multiplied by R, so `fqmul(ζ·R, x) = ζ·x` arrives
with no stray factor. The on-chip table is therefore bit-identical to the reference Kyber `zetas` array,
beginning `-1044, -758, -359, -1517`.

A table of *plain* zetas (`1, 1729, 2580, 3289…`) is the same width and the same shape and is wrong here: it
would synthesise and simulate happily and produce a transform off by a factor of R at every butterfly.
`test_twiddle_rom.py` pins `ζ[1] = -758` explicitly so that substitution cannot pass unnoticed.

### Why the multiplier is pipelined

Written combinationally, `fqmul` chains **three multipliers** back to back: the 16×16 product, then `·QINV`,
then `·q`. That is roughly 120 gate levels in sky130, or 12–18 ns — against a 20 ns period, a margin of
1.1–1.6×, which is none at all once place-and-route adds wire delay.

Three register stages put **one multiply in each**:

| stage | work |
| ----- | ---- |
| 1 | `p ← a·b` — one 16×16 |
| 2 | `m ← (p mod± R)·QINV`, with `p[31:16]` carried alongside |
| 3 | `c ← p_hi − (m·q)[31:16]` — one constant multiply and a 16-bit subtract |

Splitting the *reduction* across stages 2 and 3 matters as much as splitting off the product: folding both
constant multiplies into one cycle would simply make that the new critical path.

Barrett **is** pipelined, in two stages, and the reason is worth recording. Its input `a` reached the output
two ways: through both constant multiplies, and **directly** into the final subtract `c = a - t*q`. One net
feeding a 15 ns path and a 1 ns path makes the placer pad it to protect hold, and post-layout that net carried
**4.18 ns** of `clkdlybuf` delay before a single gate ran. Stage 1 forms the quotient and carries
`a` in its own register; stage 2 finishes.

Every op now takes **5 clocks**, `BARRETT` and `ADD` included. A uniform latency also removed a special case
from the front end.

### Operating modes

`ctrl[2:0]` selects the operation; `ctrl[3]` is `zneg`, which negates the twiddle.

| op | name | `a_out` | `b_out` | muls | used for |
| -- | ---- | ------- | ------- | ---- | -------- |
| 0 | CT | `a + fqmul(ζ,b)` | `a − fqmul(ζ,b)` | 1 | forward NTT |
| 1 | GS | `barrett(a + b)` | `fqmul(ζ, b − a)` | 1 | inverse NTT |
| 2 | FQMUL | `fqmul(a, b)` | same | 1 | scaling, basemul |
| 3 | ZMUL | `fqmul(ζ, a)` | same | 1 | basemul's twiddle multiply |
| 4 | BARRETT | `barrett(a)` | same | 0 | range control |
| 5 | ADD | `a + b` | `a − b` | 0 | polynomial add/subtract |

`FQMUL` with `b = 1` is a bare `montgomery_reduce`, which is how the host strips the residual Montgomery
factor after a round trip. `ZMUL` with `zneg` is what keeps the table on chip for `basemul`, whose twiddles are
the signed pair `±zetas[64+i]`.

### Where the silicon goes

| block | cells |
| ----- | ----- |
| `fqmul` incl. Montgomery | 2,345 |
| `barrett_reduce` | 1,058 |
| `butterfly` muxing | 670 |
| `twiddle_rom` | 468 |
| `ntt_io` | 176 |
| **total** | **4,718** |

About 37,500 µm² — **109% of a 1x2 tile's core, 53% of a 2x2**. Carrying both reductions and a signed 16-bit
datapath is what took this from the previous 2,756-cell build to 4,718.

**On SRAM macros.** `sky130_sram_1kbyte_1rw1r_32x256_8` was considered for the coefficient array and rejected
on three independent grounds. It is **479.78 × 397.5 µm**, and every tile this shuttle offers is **225.76 µm
tall** — it does not fit at any size. It is **volatile**, so a table of constants placed in it must be reloaded
at every power-up, meaning the host must still hold the table. And at 190,713 µm² it is **2.4× more expensive
than flip-flops** for 256×12 bits, with 62% of its capacity unused. Its fixed overhead — decoders, sense amps,
control — only amortises far above 3 kbit.

## How to test

Operands and results are wider than the pin budget, so the host assembles operands by **addressed byte
writes**, pulses `start`, then shifts the result back out.

### Writing operands

Put a byte on `ui_in[7:0]`, its register number on `uio_in[2:0]`, and raise `uio_in[3]` (`we`):

| addr | register | | addr | register |
| ---- | -------- | - | ---- | -------- |
| 0 | `a[7:0]` | | 4 | `k` = twiddle index `[6:0]` |
| 1 | `a[15:8]` | | 5 | `ctrl = { 4'b0, zneg, op[2:0] }` |
| 2 | `b[7:0]` | | 6, 7 | reserved |
| 3 | `b[15:8]` | | | |

Registers persist between operations, so a host walking one NTT block only rewrites the bytes that actually
changed — usually just the four operand bytes, since `k` and `ctrl` are constant across a whole block.

### Executing and reading back

A rising edge on `uio_in[4]` (`start`) launches the operation. **Every op takes 5 clocks.** Four result bytes then appear on `uo_out[7:0]`, each qualified
by `uio_out[5]` (`out_valid`), low byte first:

```
a_out[7:0]   a_out[15:8]   b_out[7:0]   b_out[15:8]
```

Values are **signed** two's complement. `uio_out[6]` (`busy`) is high from launch until the last result byte
has been presented — **poll it rather than counting clocks**, since the latency depends on the op. **The
operand registers must not be written while `busy` is high**: the datapath reads them directly for the whole
operation rather than taking its own copy.

### Running a transform

A full forward NTT is 7 layers of 128 Cooley-Tukey butterflies — **896 operations**, with the host supplying
the twiddle *index* per block. The inverse is 896 Gentleman-Sande butterflies with the index walking down,
followed by a 256-operation scaling pass by `f = R²/128 mod q = 1441` in `FQMUL` mode.

The round trip leaves one extra Montgomery factor: `INTT(NTT(f)) ≡ f·R (mod q)`. One `FQMUL(x, 1)` per
coefficient removes it.

Polynomial multiplication is `INTT(basemul(NTT(a), NTT(b)))`, composed from `FQMUL`, `ZMUL` and `ADD`.

### The tests

```sh
cd test
make                      # pin-level: all six ops, a full NTT, a round trip, basemul
make -f Makefile_bf       # the six-operation datapath over both reductions
make -f Makefile_fq       # the pipelined multiply and its Montgomery reduction
make -f Makefile_bar      # Barrett, over all 65,536 inputs
make -f Makefile_rom      # all 128 twiddle entries
python ntt_golden.py      # the model's own self-tests
```

Barrett's input space is one 16-bit word, so it is tested **completely** — all 65,536 values, which matters
because Theorem 6.2 is stated for `|a| < 2¹⁵` and `a = -32768` sits exactly on that boundary.

Several checks avoid the golden model entirely: `NTT(1)` must be `(1,0)` at every one of the 128 quadratic
factors (the CRT definition), `GS` must undo `CT` to give `2a`, each ROM entry is recomputed from
`centre(17^brv7(k)·R mod q)` inside its own test, and `test_both_reductions_are_present` requires Montgomery
and Barrett to give *different* answers related by exactly `R⁻¹` — which fails if one is quietly standing in
for the other.

## External hardware

An **FPGA or MCU** to hold the polynomial and drive the transform — for this project an **Arty A7-100T**.

Per butterfly the host reads `r[j]` and `r[j+len]`, writes the operand bytes that changed, pulses `start`, and
writes the two result halves back. It tracks the twiddle *index* `k`, which FIPS 203 already defines, and never
needs the table itself. A working reference implementation of exactly that sequencing is in `test/test.py`.
