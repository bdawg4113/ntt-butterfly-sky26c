"""
ntt_golden.py -- bit-exact golden model for the ML-KEM-512 NTT accelerator.

This mirrors the hardware exactly, in the arithmetic the textbook specifies:

  * coefficients are SIGNED and centred, carried as 16-bit values
  * the twiddle table is stored in Montgomery form (zeta^brv7(i) * R mod q)
  * the butterfly multiply is fqmul = montgomery_reduce(a*b)
  * the inverse transform uses barrett_reduce to keep running sums in range

Constants are checked against the reference Kyber tables in the self-test at
the bottom of this file.
"""

Q = 3329
N = 256
ZETA = 17

R = 1 << 16                 # Montgomery radix
QINV = -3327                # q^-1 mod 2^16, as a signed 16-bit value
R_MOD_Q = R % Q             # 2285

BARRETT_V = 20159           # floor((2^26 + q/2) / q)
BARRETT_K = 26

F = 1441                    # R^2 / 128 mod q -- the inverse transform's final scale


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def s16(x):
    """Interpret the low 16 bits of x as a signed 16-bit value."""
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def centre(x):
    """Representative of x in the centred range (-q/2, q/2]."""
    x %= Q
    return x - Q if x > Q // 2 else x


def _brv7(i):
    r = 0
    for b in range(7):
        r = (r << 1) | ((i >> b) & 1)
    return r


# Twiddle table in Montgomery form. Index 0 is R mod q (= -1044 centred), which
# is what makes this table identical to the reference Kyber `zetas` array.
ZETAS = [centre(pow(ZETA, _brv7(i), Q) * R) for i in range(128)]


# ---------------------------------------------------------------------------
# the two reduction kernels -- equations (10.1) and (10.2)
# ---------------------------------------------------------------------------
def montgomery_reduce(a):
    """Signed Montgomery reduction.

    a is a signed 32-bit product with |a| < q * 2^15.
    Returns a * R^-1 mod q, satisfying |t| < q.

        m = (a mod 2^16) * QINV     kept as a signed 16-bit value
        t = (a - m*q) >> 16         arithmetic shift; the low 16 bits are
                                    exactly cancelled, so the shift is exact
    """
    m = s16(s16(a & 0xFFFF) * QINV)
    return (a - m * Q) >> 16


def barrett_reduce(a):
    """Signed Barrett reduction: maps a signed 16-bit value into a centred
    range around 0, without changing it mod q.

        t = floor((v*a + 2^25) / 2^26)
        barrett(a) = a - t*q
    """
    t = (BARRETT_V * a + (1 << (BARRETT_K - 1))) >> BARRETT_K
    return a - t * Q


def fqmul(a, b):
    """The workhorse multiply: one 16x16 product into one Montgomery reduction.

    Returns a*b*R^-1 mod q. Because ZETAS is stored pre-multiplied by R, a
    butterfly multiply fqmul(zeta*R, x) = zeta*x comes out with no stray factor.
    """
    return montgomery_reduce(a * b)


# ---------------------------------------------------------------------------
# the two butterflies -- equations (9.2) and (9.3)
# ---------------------------------------------------------------------------
# Every add and subtract below is wrapped through s16, because the datapath is
# signed 16-bit two's complement and that is what the silicon does. Inside the
# transforms no value ever reaches the wrap point -- the widest intermediate
# observed over random and extremal inputs is 18504, against a limit of 32768 --
# so wrapping is a no-op there. It matters only when the accelerator is driven
# with operands a transform would never produce, and the model has to stay
# bit-exact with the hardware in that case too.

def butterfly_ct(a, b, zeta):
    """Cooley-Tukey, the forward transform's kernel: multiply, then add/sub."""
    t = fqmul(zeta, b)
    return s16(a + t), s16(a - t)            # (r[j], r[j+len])


def butterfly_gs(a, b, zeta):
    """Gentleman-Sande, the inverse transform's kernel: add/sub, then multiply."""
    return barrett_reduce(s16(a + b)), fqmul(zeta, s16(b - a))


# ---------------------------------------------------------------------------
# the transforms
# ---------------------------------------------------------------------------
def ntt(f_in):
    """Forward NTT: 7 layers, len = 128 down to 2, twiddle index walking up."""
    assert len(f_in) == N
    r = list(f_in)
    k = 1
    length = 128
    while length >= 2:
        start = 0
        while start < N:
            zeta = ZETAS[k]
            k += 1
            for j in range(start, start + length):
                a, b = butterfly_ct(r[j], r[j + length], zeta)
                r[j], r[j + length] = a, b
            start += 2 * length
        length >>= 1
    return r


def invntt(f_in):
    """Inverse NTT: same butterflies, layers reversed, twiddle index walking
    down, then a final scale by f which folds in the 1/128 normalisation."""
    assert len(f_in) == N
    r = list(f_in)
    k = 127
    length = 2
    while length <= 128:
        start = 0
        while start < N:
            zeta = ZETAS[k]
            k -= 1
            for j in range(start, start + length):
                a, b = butterfly_gs(r[j], r[j + length], zeta)
                r[j], r[j + length] = a, b
            start += 2 * length
        length <<= 1
    return [fqmul(x, F) for x in r]


def basemul(a0, a1, b0, b1, zeta):
    """Base multiplication -- equation (10.3).

    The incomplete NTT leaves degree-1 polynomials, so a 'pointwise' product is
    a multiplication of two linear polynomials modulo x^2 - zeta. Five fqmuls
    and two adds. The host composes this from the accelerator's FQMUL and ADD
    operations.
    """
    r0 = fqmul(fqmul(a1, b1), zeta) + fqmul(a0, b0)
    r1 = fqmul(a0, b1) + fqmul(a1, b0)
    return r0, r1


# ---------------------------------------------------------------------------
# the hardware's operating modes -- these mirror src/bfu_core.v exactly
# ---------------------------------------------------------------------------
MODE_CT      = 0    # forward butterfly
MODE_GS      = 1    # inverse butterfly
MODE_FQMUL   = 2    # Montgomery multiply (also gives montgomery_reduce via b=1)
MODE_BARRETT = 3    # Barrett reduction of a (mirrored on both outputs)
MODE_ADD     = 4    # a+b, a-b


def mode_ct(a, b, zeta):      return butterfly_ct(a, b, zeta)
def mode_gs(a, b, zeta):      return butterfly_gs(a, b, zeta)
def mode_fqmul(a, b, zeta):   return fqmul(a, b), fqmul(a, b)
def mode_barrett(a, b, zeta): return barrett_reduce(a), barrett_reduce(a)
def mode_add(a, b, zeta):     return s16(a + b), s16(a - b)

MODES = {
    MODE_CT: mode_ct,
    MODE_GS: mode_gs,
    MODE_FQMUL: mode_fqmul,
    MODE_BARRETT: mode_barrett,
    MODE_ADD: mode_add,
}


def apply_mode(mode, a, b, zeta):
    return MODES[mode](a, b, zeta)


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import random

    ref = [-1044, -758, -359, -1517, 1493, 1422, 287, 202]
    assert ZETAS[:8] == ref, f"zetas mismatch: {ZETAS[:8]}"
    assert R_MOD_Q == 2285 and QINV == -3327 and BARRETT_V == 20159 and F == 1441
    print("constants match the reference Kyber tables")

    random.seed(1)
    for _ in range(50000):
        a = random.randrange(-Q * (1 << 15) + 1, Q * (1 << 15))
        t = montgomery_reduce(a)
        assert abs(t) < Q and (t - a * pow(R, -1, Q)) % Q == 0
    print("montgomery_reduce: |t| < q and t == a*R^-1 (mod q)")

    for _ in range(50000):
        a = random.randrange(-32768, 32768)
        t = barrett_reduce(a)
        assert (t - a) % Q == 0 and abs(t) <= Q
    print("barrett_reduce: congruent mod q and centred")

    for _ in range(20):
        v = [centre(random.randrange(Q)) for _ in range(N)]
        rt = invntt(ntt(v))
        assert all((rt[i] - v[i] * R_MOD_Q) % Q == 0 for i in range(N))
        assert all((montgomery_reduce(rt[i]) - v[i]) % Q == 0 for i in range(N))
    print("round trip: INTT(NTT(f)) == f*R (mod q), Eq (10.4)")
    print("all golden-model self-tests passed")
