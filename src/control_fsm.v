// FSM that deals with address sequencing of addr_a and addr_b bits that feed into CT BU 

module control_fsm(
    input wire clk,
    input wire rst,
    input wire start,

    // outputs to memory and twiddle ROM 
    output reg  [7:0] r_addr_a,
    output reg  [7:0] r_addr_b,
    output reg  [7:0] w_addr_a,
    output reg  [7:0] w_addr_b,
    output reg  we,
    output reg  [6:0] k_idx,
    
    // Status
    output reg  done
);

    // FSM states: 
    localparam STATE_IDLE  = 3'd0;
    localparam STATE_READ  = 3'd1;
    localparam STATE_CALC  = 3'd2; // Allow combinational logic to settle
    localparam STATE_WRITE = 3'd3;
    localparam STATE_NEXT  = 3'd4;
    localparam STATE_DONE  = 3'd5;

    reg [2:0] state, next_state;

    // Loop Variables
    reg [7:0] len;
    reg [7:0] start_idx;
    reg [7:0] j;
    reg [6:0] k;

    // State Register
    always @(posedge clk) begin
        if (rst) state <= STATE_IDLE;
        else     state <= next_state;
    end

    // Next State Logic & Loop Counters
    always @(posedge clk) begin
        if (rst) begin
            len       <= 8'd128;
            start_idx <= 8'd0;
            j         <= 8'd0;
            k         <= 7'd1;
            we        <= 1'b0;
            done      <= 1'b0;
        end else begin
            // Default assignments
            we <= 1'b0;
            
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        len       <= 8'd128;
                        start_idx <= 8'd0;
                        j         <= 8'd0;
                        k         <= 7'd1;
                        done      <= 1'b0;
                    end
                end

                STATE_READ: begin
                    r_addr_a <= j;
                    r_addr_b <= j + len;
                    k_idx    <= k;
                end

                STATE_CALC: begin
                    // Wait one cycle for butterfly.v (mod_mult, mod_add, mod_sub) to compute
                    w_addr_a <= j;
                    w_addr_b <= j + len;
                end

                STATE_WRITE: begin
                    we <= 1'b1;
                end

                STATE_NEXT: begin
                    if (j < start_idx + len - 1) begin
                        // Advance inner loop
                        j <= j + 1;
                    end else begin
                        // Advance middle loop
                        if (start_idx + (len << 1) < 9'd256) begin
                            start_idx <= start_idx + (len << 1);
                            j         <= start_idx + (len << 1);
                            k         <= k + 1;
                        end else begin
                            // Advance outer loop
                            if (len > 8'd1) begin
                                len       <= len >> 1;
                                start_idx <= 8'd0;
                                j         <= 8'd0;
                                k         <= k + 1;
                            end else begin
                                // Algorithm complete
                                len <= 8'd0; // Trigger done state logic if needed
                            end
                        end
                    end
                end
                
                STATE_DONE: begin
                    done <= 1'b1;
                end
            endcase
        end
    end

// Combinational Next State Transition
    always @(*) begin
        next_state = state;
        case (state)
            STATE_IDLE:  if (start) next_state = STATE_READ;
            STATE_READ:  next_state = STATE_CALC;
            STATE_CALC:  next_state = STATE_WRITE;
            STATE_WRITE: next_state = STATE_NEXT;
            
            // originally the FSM finished on the last stage at len = 2
            // because len = 2 during the cycle where len > 8'd1, then 2 > 1 would evaluate to true 
            // and FSM loops back to STATE_READ again, which it should not have done 
            // sequential block shifted down to 1 but the FSM entered a rogue len = 1 stage and started computing 
            // a BU on index 0 and index 1
            // fix: changed else if statement to settle the next state at 9'd256

            STATE_NEXT: begin
                if (j < start_idx + len - 1) 
                    next_state = STATE_READ; // Inner loop continues
                else if (start_idx + (len << 1) < 9'd256) 
                    next_state = STATE_READ; // Middle loop continues
                else if (len > 8'd2) 
                    next_state = STATE_READ; // Outer loop continues
                else 
                    next_state = STATE_DONE; // Entire NTT is finished
            end
            
            STATE_DONE:  next_state = STATE_IDLE;
        endcase
    end

endmodule