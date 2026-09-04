## Python file to feed 256 twiddle ROM coefficients into Arty A7 via a USB-UART bridge 

import serial 
import time 
import struct 

# Configure COM port that matches with the Arty: 
ser = serial.Serial('/dev/ttyUSB1', 115200, timeout = 5.0) 

def write_coeff(addr, val): 
    lsb = val & 0xFF
    msb = (val >> 8) & 0x0F 
    ser.write(struct.pack('BBBB', 0x01, addr, lsb, msb))
    time.sleep(0.001) 

def read_coeff(addr): 
    ser.write(struct.pack('BB', 0x02, addr))
    res = ser.read(2)
    return res[0] | (res[1] << 8)

def run_engine(command_byte):
    ser.write(struct.pack('B', command_byte))
    ack = ser.read(1)
    if ack == b'\xAA':
        print("Engine execution completed")

# Steps to run: 

print("Loading Polynomial")
# 1. Load some polynomial into the FSM: 
original_poly = [(i * 17 + 5) % 3329 for i in range(256)]
for i, coeff in enumerate(original_poly):
    write_coeff(i, coeff)

# 2. trigger forward NTT:
print("Running Forward NTT...") 
run_engine(0x03)

# 3. Read back the transformed polynomial after forward NTT runs: 
ntt_poly = [read_coeff(i) for i in range(256)]
print(f"First 5 NTT Coeffs: {ntt_poly[:5]}")

# 4. Trigger Inverse NTT: 
print("Running Inverse NTT...")
run_engine(0x04)

# 5. Read back and verify: 
final_poly = [read_coeff(i) for i in range(256)]
if final_poly == original_poly: 
    print("SUCCESS: INTT(NTT(f))==f")
else: 
    print("FAIL: Mismatch Detected")