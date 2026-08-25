# Generates hex file that feeds known coeffs into coeff_mem.v for verification purposes 
# located in: /test/init_coeffs.hex 

import random
import os

def generate_hex_file(filename="../test/init_coeffs.hex"):

    os.makedirs(os.path.dirname(filename), exist_ok = True)
    # Fixed seed ensures reproducible test vectors every time you run it
    random.seed(42)
    
    # ML-KEM prime modulus
    Q = 3329
    
    # We need exactly 256 coefficients for one NTT polynomial
    num_coeffs = 256
    
    # Store the integer values so you can pass them to your golden model later
    golden_model_inputs = []
    
    with open(filename, "w") as f:
        for _ in range(num_coeffs):
            # Generate a field element between 0 and 3328
            val = random.randint(0, Q - 1)
            golden_model_inputs.append(val)
            
            # Format as 3-digit uppercase hex (e.g., 3328 -> 'D00', 15 -> '00F')
            f.write(f"{val:03X}\n")
            
    print(f"Successfully generated '{filename}' with {num_coeffs} coefficients.")
    
    # Optional: print the first few values to verify
    print(f"First 5 integers: {golden_model_inputs[:5]}")

if __name__ == "__main__":
    generate_hex_file()