# Tests for the ML-KEM NTT/INTT accelerator

All tests use [cocotb](https://docs.cocotb.org/en/stable/) with Icarus Verilog, and check against
`ntt_golden.py` — a bit-exact model of the hardware whose constants are verified against the reference
Kyber tables (`zetas` starting `-1044, -758, -359, -1517`, `QINV = -3327`, `v = 20159`, `f = 1441`).

| Command | What it covers |
| ------- | -------------- |
| `make` | **The hardened design.** Drives `tt_um_ntt` through the TT pins only: all five modes, the twiddle ROM, a complete 256-point forward NTT, and an NTT→INTT round trip that recovers the original polynomial. |
| `make -f Makefile_bfu` | The five-mode arithmetic core: each mode alone, a mixed-mode stream at full rate (results must not reorder), a randomly gapped stream, and `FQMUL(x,1) == montgomery_reduce(x)`. |
| `make -f Makefile_arith` | `fqmul` and `montgomery_reduce` over random and edge-case operands. |
| `make -f Makefile_barrett` | `barrett_reduce`: congruent mod q and correctly centred. |
| `make -f Makefile_rom` | All 128 Montgomery-form twiddle entries. |

The most important is `make`. `test_ntt_intt_round_trip` plays the part of the host FPGA: it holds the
256-coefficient polynomial in Python, walks the FIPS 203 address pattern, and streams all 896 forward
butterflies, then all 896 inverse butterflies plus the 256-operation scaling pass, through the chip's pins.
It checks that the round trip returns `f·R (mod q)` per Eq (10.4), and that one `montgomery_reduce` recovers
the original coefficients exactly.

`python ntt_golden.py` runs the model's own self-tests standalone.

## Gate-level simulation

Harden the project first, copy `runs/wokwi/results/final/verilog/gl/tt_um_ntt.v` to
`gate_level_netlist.v`, then:

```sh
make -B GATES=yes
```

The tests read pins through helpers that treat `X`/`Z` as 0, so the same `test.py` runs against both RTL
and the post-layout netlist.

## Waveforms

`make` writes `tb.fst`:

```sh
gtkwave tb.fst tb.gtkw     # or: surfer tb.fst
```

## Regenerating the twiddle ROM

```sh
python scripts/generate_twiddle.py > src/twiddle_rom.v
```
