q, zc = 3329, 17 

def bitrev7(i): 
    r=0 
    for b in range(7): 
        r = (r<<1)|((i>>b)&1)
    return r 

lines = ["module twiddle_rom (",
         "    input  wire [6:0]  k,",
         "    output reg  [11:0] zeta",
         ");",
         "    always @(*) begin",
         "        case (k)"]
for k in range(1,128):
    lines.append(f"            7'd{k}: zeta = 12'd{pow(zc,bitrev7(k),q)};")
lines += ["            default: zeta = 12'd0;",
          "        endcase",
          "    end",
          "endmodule"]

open("src/twiddle_rom.v","w").write("\n".join(lines)+"\n")