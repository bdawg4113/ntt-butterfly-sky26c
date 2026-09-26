## Python file to feed 256 twiddle ROM coefficients into Arty A7 via a USB-UART bridge 

import serial 
import time 
import struct 
import random 

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
    if len(res) < 2:
        raise TimeoutError(f"UART read timed out at address {addr}. FPGA is not responding.")
    return res[0] | (res[1] << 8)

def run_engine(command_byte):
    ser.write(struct.pack('B', command_byte))
    ack = ser.read(1)
    if ack == b'\xAA':
        print("Engine execution completed")
    else:
        raise TimeoutError("FPGA did not send completion ACK. Is the engine stuck?")

# Steps to run: 

# print("Loading Polynomial")
# # 1. Load some polynomial into the FSM: 
# original_poly = [(i * 17 + 5) % 3329 for i in range(256)]
# for i, coeff in enumerate(original_poly):
#     write_coeff(i, coeff)

# --- Replace Step 1 with this Interactive Menu --- 

print("\n=== Interactive NTT Hardware Accelerator ===")
print("How would you like to generate the 256-coefficient polynomial?")
print("  [1] Enter custom comma-separated values")
print("  [2] Generate a completely random polynomial")
print("  [3] Use the default linear test formula")

choice = input("Select an option (1-3): ").strip()
original_poly = [0] * 256  # Initialize an empty array of 256 zeros

if choice == '1':
    user_str = input("Enter coefficients (e.g., 10, 20, 30...): ")
    if user_str:
        try:
            # Parse input, convert to int, and safely modulo 3329
            user_vals = [int(x.strip()) % 3329 for x in user_str.split(',')]
            
            # Copy user values into the array (zero-padding the rest)
            for i in range(min(len(user_vals), 256)):
                original_poly[i] = user_vals[i]
                
            print(f"Loaded {len(user_vals)} custom coefficients. Zero-padding the rest.")
        except ValueError:
            print("Invalid input detected. Falling back to an array of zeros.")
            
elif choice == '2':
    original_poly = [random.randint(0, 3328) for _ in range(256)]
    print("Generated an array of 256 random coefficients.")
    
else:
    original_poly = [(i * 17 + 5) % 3329 for i in range(256)]
    print("Loaded default linear formula.")

print("\nLoading Polynomial into FPGA Memory...")
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

# # 5. Read back and verify: 
# final_poly = [read_coeff(i) for i in range(256)]
# if final_poly == original_poly: 
#     print("SUCCESS: INTT(NTT(f))==f")
# else: 
#     print("FAIL: Mismatch Detected")

# 5. Read back and verify in real time: 
print("\nStreaming Final Coefficients from FPGA...")
print("-" * 60)

match_count = 0
for i in range(256):
    final_val = read_coeff(i)
    orig_val = original_poly[i]
    
    # Format the raw value as a 12-bit binary string (e.g., '000001100000')
    bin_str = f"{final_val:012b}"
    
    # Print the live comparison
    print(f"Index {i:3} | Bin: {bin_str} -> Int: {final_val:4} | Expected: {orig_val:4} ", end="")
    
    if final_val == orig_val:
        print("✅ PASS")
        match_count += 1
    else:
        print("❌ FAIL")
        
    # Optional: uncomment the line below to artificially slow down the terminal output 
    # so a viewer can easily read it as it scrolls by
    # time.sleep(0.02) 

print("-" * 60)
if match_count == 256: 
    print("SUCCESS: INTT(NTT(f)) == f for all 256 coefficients!")
else: 
    print(f"FAIL: {256 - match_count} mismatches detected.")