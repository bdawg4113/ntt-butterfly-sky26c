![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# ML-KEM-512 NTT/INTT Accelerator

A Number Theoretic Transform accelerator for **ML-KEM-512** (FIPS 203, formerly Kyber), built entirely on an
open source flow: open PDK (SkyWater SKY130), open RTL to GDSII flow (LibreLane), open simulation (Icarus and
cocotb), and an open shuttle (Tiny Tapeout).

Full datasheet: **[docs/info.md](docs/info.md)**

## What it does

The chip is the **modular arithmetic engine** of the transform. It carries **both reduction kernels**,
Montgomery and Barrett, and the **128-entry twiddle table** on die. A host holds the 256-coefficient
polynomial and walks the FIPS 203 address pattern; the chip does the arithmetic and looks up its own
constants, so the host sends a twiddle **index** and never a value.

Six operations cover the forward transform, the inverse transform and `basemul`:

| op | name | `a_out` | `b_out` | used for |
| -- | ---- | ------- | ------- | -------- |
| 0 | CT | `a + fqmul(ζ,b)` | `a − fqmul(ζ,b)` | forward NTT |
| 1 | GS | `barrett(a + b)` | `fqmul(ζ, b − a)` | inverse NTT |
| 2 | FQMUL | `fqmul(a, b)` | same | scaling, basemul |
| 3 | ZMUL | `fqmul(ζ, a)` | same | basemul's twiddle multiply |
| 4 | BARRETT | `barrett(a)` | same | range control |
| 5 | ADD | `a + b` | `a − b` | polynomial add and subtract |

Values are signed 16-bit and centred; `q = 3329`, `R = 2¹⁶`. Every operation takes 5 clocks.

## Results

Hardened on a **2x2 tile**, closing **50 MHz**:

| | |
| --- | --- |
| Technology | SkyWater SKY130, 130 nm, 1.80 V |
| Die area | 334.88 × 225.76 µm (75,603 µm²) |
| Standard cells | 6,067, 52,731 µm² |
| Core utilization | 72.7% |
| Worst setup slack | **+1.955 ns**, 0 violations at all nine corners |
| Worst hold slack | +0.106 ns, 0 violations |
| DRC / LVS / antenna / latches | 0 / 0 / 0 / 0 |
| Total power | 2.623 mW |
| Routed wire | 128,063 µm across 5,023 nets |

The arithmetic is 72% of the design. There are **no macros**: `design__instance__area__macros = 0`.

## Layout

```
        pins  <-------> ntt_io          operand registers, launch, unload
                           |
              +------------+------------+
              |                         |
        twiddle_rom               butterfly            CT GS FQMUL ZMUL BARRETT ADD
        128 x 12                   |      |
        Montgomery                 |      |
                                 fqmul  barrett_reduce
                                 5-stage    2-stage
                                 Thm 6.1    Thm 6.2
```

## Testing

```sh
cd test
make                      # pin level: all six ops, a full NTT, a round trip, basemul
make -f Makefile_bf       # the six operation datapath over both reductions
make -f Makefile_fq       # the pipelined multiply and its Montgomery reduction
make -f Makefile_bar      # Barrett, over all 65,536 inputs
make -f Makefile_rom      # all 128 twiddle entries
python ntt_golden.py      # the model's own self tests
```

27 tests. Several avoid the golden model entirely, so a misreading of FIPS 203 cannot hide in the model and
the hardware together: `NTT(1)` must be `(1,0)` at all 128 quadratic factors, `GS` must undo `CT` to give
`2a`, each ROM entry is recomputed from `centre(17^brv7(k)·R mod q)` inside its own test, and Montgomery and
Barrett are required to return *different* answers related by exactly `R⁻¹`.

See [test/README.md](test/README.md) for detail.

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)
