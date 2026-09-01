# Tests for the ML-KEM NTT/INTT accelerator

All tests use [cocotb](https://docs.cocotb.org/en/stable/) with Icarus Verilog and check against
`ntt_golden.py` — a bit-exact model of the hardware, one Python function per Verilog module.

| Command | What it covers |
| ------- | -------------- |
| `make` | **The hardened design.** Drives `tt_um_ntt` through the TT pins only: all five ops, reading all 128 twiddles back out of the chip's own ROM by index, register persistence, a full forward NTT, an NTT->INTT round trip, `basemul`, and that `ADD` is quicker than a multiply. |
| `make -f Makefile_bf` | The shared five-operation datapath: each op with its latency checked constant, 600 operations with the op changing every time, that GS undoes CT, that MUL ignores the twiddle and ZMUL ignores `b`, and which outputs mirror. |
| `make -f Makefile_mult` | The three-stage pipelined Barrett multiplier: exactly 3 clocks of latency, 2,000 multiplies issued one per clock in order, and the worst-case products for the two conditional subtracts. |
| `make -f Makefile_rom` | All 128 twiddle entries against `17^brv7(k) mod q`, and that the table is plain rather than Montgomery. |
| `python ntt_golden.py` | The model's own self-tests, including Barrett checked exhaustively over all 11,082,241 products. |

## Tests that do not trust the model

Everything else compares the RTL against `ntt_golden.py` — but that model is ours. If we had misread FIPS 203,
model and hardware would be wrong together and everything would still pass. Five checks avoid that:

- **`ntt_golden.py`'s CRT check.** The incomplete NTT is a Chinese Remainder Theorem map, so `NTT(f)[2i]` and
  `NTT(f)[2i+1]` must be exactly `f` reduced modulo `x² − ζ^(2·brv7(i)+1)`. No layer, twiddle order or
  butterfly enters into that statement.
- **`test.py::test_known_vector`.** `NTT(1)` must be `(1, 0)` at every one of the 128 quadratic factors,
  because the constant polynomial is already its own remainder. Written down from the definition, not computed.
- **`test.py::test_twiddle_rom_is_on_chip`.** All 128 twiddles read back out of the chip through `ZMUL` with
  `a = 1`, plus the negated half. Nowhere in `test.py` is a twiddle value written to the chip.
- **`test_butterfly.py::test_ct_gs_are_inverse`.** `GS(CT(a, b, ζ), ζ)` must have `2a` as its first output —
  a property of the two butterflies being genuine inverses, checked against the hardware alone.
- **`test_twiddle_rom.py`.** Each entry recomputed from `17^brv7(k) mod q` inside the test, and `ζ[1]` pinned
  to `1729` so a Montgomery table cannot pass.

## Operation timing

| op | clocks to the first result byte |
| -- | ------------------------------- |
| `ADD` | 0 — no multiply, the result is combinational |
| `CT`, `GS`, `MUL`, `ZMUL` | 3 |

Poll `busy` rather than counting clocks: the latency is not the same for every op, which is what
`test_add_is_single_cycle` demonstrates. **Do not write the operand registers while `busy` is high** — the
datapath reads them directly for the whole operation rather than taking its own copy.

## Regenerating the twiddle ROM

`src/twiddle_rom.v` is generated. If it is ever edited by hand, regenerate instead:

```sh
python scripts/generate_twiddle.py
```

The generator asserts the table head and the 12-bit fit before writing, so a wrong table fails there rather
than in silicon.

## Gate-level simulation

Harden the project first, copy `runs/wokwi/results/final/verilog/gl/tt_um_ntt.v` to `gate_level_netlist.v`,
then:

```sh
make -B GATES=yes
```

The tests read pins through helpers that treat `X`/`Z` as 0, so the same `test.py` runs against both RTL and
the post-layout netlist.

## Waveforms

`make` writes `tb.fst`:

```sh
gtkwave tb.fst tb.gtkw     # or: surfer tb.fst
```
