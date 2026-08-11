import cocotb
from cocotb.triggers import Timer 
import random 

Q = 3329 

def golden(a,b,zeta): 
    t = (zeta * b) % Q
    return (a + t) % Q, (a - t) % Q 

@cocotb.test
async def test_butterfly(dut): 
    random.seed(1) 
    cases = [(0,0,1),(1,1,1),(3328,3328,1729),(100,200,17)]
    cases += [(random.randrange(Q), random.randrange(Q), random.randrange(Q))
              for _ in range(5000)]
    for a, b, z in cases:
        dut.a.value = a
        dut.b.value = b
        dut.zeta.value = z
        await Timer(1, units="ns")
        exp_a, exp_b = golden(a, b, z)
        assert dut.a_out.value == exp_a, f"a_out: {a},{b},{z} got {int(dut.a_out.value)} exp {exp_a}"
        assert dut.b_out.value == exp_b, f"b_out: {a},{b},{z} got {int(dut.b_out.value)} exp {exp_b}"