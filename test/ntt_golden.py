"""
ntt_golden.py -- bit-exact golden model for the ML-KEM-512 NTT/INTT accelerator.

This mirrors the hardware exactly, in the arithmetic the silicon uses:

  * coefficients are UNSIGNED field elements in [0, q), carried as 12 bits
  * the twiddle table holds PLAIN zetas, zeta^brv7(k) mod q
  * the butterfly multiply is Barrett reduction: (a*b) mod q, no Montgomery
  * the inverse transform closes with a scale by n^-1 = 128^-1 mod q = 3303

That is a different convention from the reference Kyber C code, which works in
signed centred representatives and Montgomery form. Both compute the same
transform; this one is chosen because a Barrett datapath multiplies by zeta
directly and never has a Montgomery factor to unwind, which is what makes the
inverse transform's closing pass a plain 1/n instead of R^2/n.

The self-test at the bottom checks the forward transform against the CRT map
FIPS 203 actually defines, independently of how it is computed here.
"""

Q = 3329
N = 256
ZETA = 17

# Barrett constants -- these are the numbers in src/mod_mult.v.
# The quotient is estimated from the top of the product only: shifting T right
# by BARRETT_S first turns a 24x13 constant multiply into a 13x13 one.
BARRETT_MU = (1 << 24) // Q             # 5039
BARRETT_S = 11                          # bits of T discarded before the estimate
BARRETT_T = 13                          # bits shifted off after it

# The inverse transform's closing scale: n^-1 mod q for n = 128.
NINV = pow(128, -1, Q)                  # 3303


def _brv7(i):
    r = 0
    for b in range(7):
        r = (r << 1) | ((i >> b) & 1)
    return r


# The on-chip twiddle table, exactly as src/twiddle_rom.v holds it.
ZETAS = [pow(ZETA, _brv7(i), Q) for i in range(128)]


# ---------------------------------------------------------------------------
# the arithmetic primitives -- one Python function per Verilog module
# ---------------------------------------------------------------------------
def mod_add(a, b):
    """src/mod_add.v: a + b < 2q, so one conditional subtract."""
    s = a + b
    return s - Q if s >= Q else s


def mod_sub(a, b):
    """src/mod_sub.v: q is added first so the intermediate stays unsigned."""
    d = a + Q - b
    return d - Q if d >= Q else d


def barrett_remainder(t):
    """The remainder src/mod_mult.v forms before its conditional subtracts.

        quo = ((T >> 11) * MU) >> 13

    Estimating the quotient from the top of T only costs accuracy -- the
    remainder lands in [0, 6936) rather than [0, 2q) -- and buys half the
    constant multiplier. The self-test walks every reachable product to pin
    that bound down.
    """
    return t - (((t >> BARRETT_S) * BARRETT_MU) >> BARRETT_T) * Q


def mod_mult(a, b):
    """src/mod_mult.v: Barrett reduction, step for step.

    Written out rather than as (a*b) % q so that the model fails if the
    hardware's constants ever drift. The two agree for every pair below q,
    which the self-test checks exhaustively over the reachable products.
    """
    r = barrett_remainder(a * b)
    if r >= Q:
        r -= Q
    if r >= Q:
        r -= Q
    return r


# ---------------------------------------------------------------------------
# the butterflies -- src/butterfly.v
# ---------------------------------------------------------------------------
def butterfly_ct(a, b, zeta):
    """Cooley-Tukey, the forward kernel: multiply, then add and subtract."""
    t = mod_mult(zeta, b)
    return mod_add(a, t), mod_sub(a, t)


def butterfly_gs(a, b, zeta):
    """Gentleman-Sande, the inverse kernel: subtract, then multiply."""
    return mod_add(a, b), mod_mult(zeta, mod_sub(b, a))


def scale(a):
    """The inverse transform's closing multiply by 1/n.

    On chip this is an ordinary OP_MUL with NINV supplied as the b operand --
    there is no dedicated scaling op, because one constant is not worth a mux
    input when the host is already sequencing every operation.
    """
    return mod_mult(a, NINV)


# ---------------------------------------------------------------------------
# the transforms -- the HOST walks these loops, streaming each butterfly
# through the chip. The chip supplies the twiddle from its own ROM, so the
# host passes the index k rather than the value ZETAS[k].
# ---------------------------------------------------------------------------
def ntt(f_in):
    """Forward NTT: 7 layers, len from 128 down to 2, k walking up from 1."""
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
                r[j], r[j + length] = butterfly_ct(r[j], r[j + length], zeta)
            start += 2 * length
        length >>= 1
    return r


def invntt(f_in):
    """Inverse NTT: layers reversed, k walking down from 127, then scale by 1/n."""
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
                r[j], r[j + length] = butterfly_gs(r[j], r[j + length], zeta)
            start += 2 * length
        length <<= 1
    return [scale(x) for x in r]


# the datapath's five operations, as src/butterfly.v numbers them
OP_CT, OP_GS, OP_MUL, OP_ZMUL, OP_ADD = 0, 1, 2, 3, 4

OP_NAMES = {OP_CT: "CT", OP_GS: "GS", OP_MUL: "MUL",
            OP_ZMUL: "ZMUL", OP_ADD: "ADD"}


def apply_op(op, a, b, zeta):
    """Mirrors src/butterfly.v exactly, including which outputs are mirrored."""
    if op == OP_CT:
        return butterfly_ct(a, b, zeta)
    if op == OP_GS:
        return butterfly_gs(a, b, zeta)
    if op == OP_MUL:
        t = mod_mult(a, b)
        return t, t
    if op == OP_ZMUL:
        t = mod_mult(zeta, a)
        return t, t
    return mod_add(a, b), mod_sub(a, b)          # OP_ADD


def basemul(a0, a1, b0, b1, zeta):
    """Base multiplication: the pointwise product of the incomplete NTT.

    The transform leaves degree-1 polynomials, so a 'pointwise' product is a
    multiplication of two linear polynomials modulo x^2 - zeta. Five multiplies
    and two adds, which the host composes from OP_MUL, OP_ZMUL and OP_ADD --
    OP_ZMUL is what keeps the twiddle table on chip for this, since its
    twiddles are the signed pair +/-zetas[64+i].
    """
    r0 = mod_add(mod_mult(mod_mult(a1, b1), zeta), mod_mult(a0, b0))
    r1 = mod_add(mod_mult(a0, b1), mod_mult(a1, b0))
    return r0, r1


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import random

    assert ZETAS[:8] == [1, 1729, 2580, 3289, 2642, 630, 1897, 848]
    assert BARRETT_MU == 5039 and NINV == 3303
    assert max(ZETAS) < 4096, "the table must fit 12 bits"
    print("constants match: zetas start 1, 1729, 2580, 3289; MU = 5039; 1/n = 3303")

    # Barrett must equal the modulo it replaces, for every product that can
    # reach it -- both operands are field elements, so T < q^2.
    for a in range(Q):
        b = (a * 7919 + 13) % Q          # a stride that visits every residue
        assert mod_mult(a, b) == (a * b) % Q, f"mod_mult({a},{b})"
    worst = 0
    for t in range((Q - 1) * (Q - 1) + 1):
        r = barrett_remainder(t)
        assert r >= 0, f"the quotient estimate overshot at T = {t}"
        if r > worst:
            worst = r
    assert worst < 3 * Q, "two conditional subtracts are not enough"
    assert worst < (1 << 13), "the remainder does not fit the 13-bit datapath"
    print(f"Barrett: exact over all reachable products; worst pre-subtract "
          f"remainder {worst} -- under 3q = {3 * Q} (two subtracts) and under "
          f"2^13 = 8192 (13-bit datapath)")

    # An INDEPENDENT check of the forward transform.
    #
    # Every other test compares the RTL against this model -- but this model is
    # ours. If we had misread FIPS 203, model and hardware would be wrong
    # together and everything would still pass. So check the transform against
    # its mathematical definition instead, with no reference to how it is
    # computed: the incomplete NTT is a Chinese Remainder Theorem map, and
    # NTT(f)[2i], NTT(f)[2i+1] must be exactly f reduced modulo the quadratic
    # factor x^2 - zeta^(2*brv7(i)+1). No layer, twiddle order or butterfly
    # enters into that statement.
    def _poly_mod_quadratic(f, gamma):
        r0 = r1 = 0
        for j in range(N):
            kk, odd = divmod(j, 2)
            term = f[j] * pow(gamma, kk, Q) % Q
            if odd:
                r1 = (r1 + term) % Q
            else:
                r0 = (r0 + term) % Q
        return r0, r1

    random.seed(1)
    for _ in range(2):
        f = [random.randrange(Q) for _ in range(N)]
        fhat = ntt(f)
        assert all(0 <= x < Q for x in fhat), "a coefficient left the field"
        for i in range(128):
            gamma = pow(ZETA, 2 * _brv7(i) + 1, Q)
            assert (fhat[2 * i], fhat[2 * i + 1]) == _poly_mod_quadratic(f, gamma), \
                f"NTT is not the CRT map at quadratic factor {i}"
    print("forward NTT is the CRT map FIPS 203 defines (independent of our butterflies)")

    # In plain arithmetic the round trip is exact -- there is no Montgomery
    # factor left over to strip, which is the whole reason the closing scale is
    # 1/n and not R^2/n.
    for _ in range(20):
        v = [random.randrange(Q) for _ in range(N)]
        assert invntt(ntt(v)) == v, "round trip did not return the original"
    print("round trip: INTT(NTT(f)) == f exactly, no residual factor")

    # basemul must agree with an honest polynomial multiply mod x^2 - zeta
    for _ in range(2000):
        a0, a1, b0, b1 = (random.randrange(Q) for _ in range(4))
        z = random.choice(ZETAS)
        want = ((a0 * b0 + a1 * b1 * z) % Q, (a0 * b1 + a1 * b0) % Q)
        assert basemul(a0, a1, b0, b1, z) == want
    print("basemul is multiplication mod x^2 - zeta")

    print("all golden-model self-tests passed")
