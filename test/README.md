# Tests for the NTT butterfly accelerator

All tests use [cocotb](https://docs.cocotb.org/en/stable/) with Icarus Verilog.

| Command | What it covers |
| ------- | -------------- |
| `make` | **The hardened design.** Drives `tt_um_ntt` through the Tiny Tapeout pins only: directed and random butterflies, a complete 256-point ML-KEM forward NTT, and the `uio_oe` direction map. |
| `make -f Makefile_bf` | The pipelined `butterfly` on its own: back-to-back at one per clock, a randomly gapped stream, and a reset mid-flight. |
| `make -f Makefile_rom` | All 127 twiddle ROM entries plus the default. |
| `make -f Makefile_top` | The **reference** `ntt_top` sequencer (on-chip coefficient array) against `ntt_golden.py`. Not part of the taped-out design — see the header in `src/ntt_top.v`. |

The most important one is `make`: `test_full_ntt_through_pins` sequences all 896 butterflies of a real
ML-KEM forward NTT across the chip's pins exactly the way the host FPGA will, then checks all 256 output
coefficients against the golden model in `ntt_golden.py`.

## Gate-level simulation

Harden the project first, copy `runs/wokwi/results/final/verilog/gl/tt_um_ntt.v` to
`gate_level_netlist.v`, then:

```sh
make -B GATES=yes
```

The tests read pins through helpers that treat `X`/`Z` as 0, so the same `test.py` runs against both RTL
and the post-layout netlist.

## Waveforms

`make` writes `tb.fst`. View it with:

```sh
gtkwave tb.fst tb.gtkw     # or: surfer tb.fst
```

For a waveform of the butterfly alone, without cocotb:

```sh
iverilog -g2012 -o sim_bf tb_butterfly.v ../src/butterfly.v \
         ../src/mod_mult.v ../src/mod_add.v ../src/mod_sub.v && vvp sim_bf
```
