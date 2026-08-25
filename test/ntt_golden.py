"""
ntt_golden.py — RTL-structured golden model for the ML-KEM forward NTT.

Mirrors the hardware exactly:
  - twiddles are precomputed once into a table (like the ROM), never
    computed on the fly via modpow during the transform
  - add/sub use the hardware conditional-+-q / conditional--q idiom,
    matching mod_add.v / mod_sub.v bit-for-bit
  - the loop structure (len, start, j, k) matches control_fsm.v's
    intended address/twiddle sequence exactly

Use this as the ground truth model for the top-level cocotb test (ntt_top vs this).
"""

Q = 3329
N = 256
ZETA = 17

# ---------------------------------------------------------------------------
# Twiddle table — precomputed once, exactly like twiddle_rom.v's contents.
# ---------------------------------------------------------------------------
def _bitrev7(i: int) -> int:
    r = 0
    for b in range(7):
        r = (r << 1) | ((i >> b) & 1)
    return r

def _modpow(base, exp, mod):
    result = 1
    base %= mod
    while exp > 0:
        if exp & 1:
            result = (result * base) % mod
        base = (base * base) % mod
        exp >>= 1
    return result

# ZETAS[k] for k = 1..127 ; ZETAS[0] unused (mirrors ROM's default = 0)
ZETAS = [0] + [_modpow(ZETA, _bitrev7(k), Q) for k in range(1, 128)]


# ---------------------------------------------------------------------------
# Hardware-style modular arithmetic (matches mod_add.v / mod_sub.v exactly)
# ---------------------------------------------------------------------------
def hw_add(a: int, b: int) -> int:
    s = a + b
    return s - Q if s >= Q else s

def hw_sub(a: int, b: int) -> int:
    d = a + Q - b          # add Q first so it never goes negative
    return d - Q if d >= Q else d

def hw_mult(a: int, b: int) -> int:
    # behaviorally equivalent to the Barrett mod_mult; golden model just
    # uses %, since correctness of mod_mult.v is verified separately
    return (a * b) % Q


# ---------------------------------------------------------------------------
# The butterfly — matches butterfly.v's port semantics exactly
# ---------------------------------------------------------------------------
def butterfly(a: int, b: int, zeta: int):
    t = hw_mult(zeta, b)
    a_out = hw_add(a, t)
    b_out = hw_sub(a, t)
    return a_out, b_out


# ---------------------------------------------------------------------------
# Full forward NTT — 7-stage incomplete transform, FIPS 203 Algorithm 9.
# Loop structure mirrors control_fsm.v's intended (len, start, j, k) walk.
# ---------------------------------------------------------------------------
def ntt(f_in):
    """f_in: list of 256 ints in [0, Q). Returns transformed list (new copy)."""
    assert len(f_in) == N
    f = list(f_in)
    k = 1
    length = 128
    while length >= 2:
        start = 0
        while start < N:
            zeta = ZETAS[k]
            k += 1
            for j in range(start, start + length):
                a_out, b_out = butterfly(f[j], f[j + length], zeta)
                f[j] = a_out
                f[j + length] = b_out
            start += 2 * length
        length //= 2
    return f


# ---------------------------------------------------------------------------
# Address/twiddle trace generator — for verifying control_fsm.v's sequencing
# independently of any arithmetic (dump this, diff against the FSM's
# emitted (addr_a, addr_b, k) sequence).
# ---------------------------------------------------------------------------
def address_trace():
    """Yields (stage, addr_a, addr_b, k) for all 896 butterflies in order."""
    k = 1
    length = 128
    stage = 0
    while length >= 2:
        start = 0
        while start < N:
            for j in range(start, start + length):
                yield (stage, j, j + length, k)
            k += 1
            start += 2 * length
        length //= 2
        stage += 1


if __name__ == "__main__":
    # quick self-check: known first twiddle, and a round of sanity stats
    assert ZETAS[1] == 1729, f"ZETAS[1] should be 1729, got {ZETAS[1]}"

    trace = list(address_trace())
    print(f"total butterflies: {len(trace)} (expect 896)")
    print(f"total distinct k used: {trace[-1][3]} (expect 127)")
    print(f"first 3 entries: {trace[:3]}")
    print(f"last 3 entries:  {trace[-3:]}")

    # round-trip-free correctness spot check: NTT of unit impulse-ish vector
    import random
    random.seed(0)
    f = [random.randrange(Q) for _ in range(N)]
    out = ntt(f)
    print(f"NTT ran on random input, output[0..4] = {out[:5]}")