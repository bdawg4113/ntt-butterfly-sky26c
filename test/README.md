# Tests for the ML-KEM NTT/INTT accelerator

All tests use [cocotb](https://docs.cocotb.org/en/stable/) with Icarus Verilog, and check against
`ntt_golden.py` — a bit-exact model of the hardware whose constants are verified against the reference
Kyber tables (`zetas` starting `-1044, -758, -359, -1517`, `QINV = -3327`, `f = 1441`).

| Command | What it covers |
| ------- | -------------- |
| `make` | **The hardened design.** Drives `tt_um_ntt` through the TT pins only: all five modes, register persistence, a complete 256-point forward NTT, and an NTT→INTT round trip that recovers the original polynomial. |
| `make -f Makefile_bfu` | The five-mode arithmetic core: each mode with its latency checked constant, 400 operations with the mode changing every time, the `busy` protocol, and that `MODE_REDUCE` returns a centred representative of the same residue. |
| `make -f Makefile_serfq` | The serial Montgomery multiply, including that `b = 1` gives a bare `montgomery_reduce` and `b = R mod q` gives a range reduction. |

The most important is `make`. `test_ntt_intt_round_trip` plays the part of the host FPGA: it holds the
256-coefficient polynomial in Python, walks the FIPS 203 address pattern, and streams all 896 forward
butterflies, then all 896 inverse butterflies plus the 256-operation scaling pass, through the chip's pins.
It checks that the round trip returns `f·R (mod q)` per Eq (10.4), and that one `montgomery_reduce` recovers
the original coefficients exactly.

`python ntt_golden.py` runs the model's own self-tests standalone.

## Operation timing

The core is multi-cycle, not pipelined, so latency depends on the mode:

| mode | clocks | multiplies |
| ---- | ------ | ---------- |
| `ADD` | 1 | 0 |
| `CT`, `FQMUL`, `REDUCE` | 20 | 1 |
| `GS` | 39 | 2 |

Poll `busy` rather than counting clocks. **Do not write the operand registers while `busy` is high** — the
core reads them directly for the whole operation rather than taking its own copy.

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
