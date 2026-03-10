// ============================================================
// OOK TX SERIALIZER
// ============================================================
// Frame: [SYNC=1][qubit_bit1][qubit_bit0][IDLE=0]
// Each slot = slot_width clock cycles
// Total frame = 4 × slot_width + gap
// ============================================================
module ook_tx_serializer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tx_start,       // Pulse to begin sending
    input  wire [1:0]  qubit_in,       // Qubit to transmit
    input  wire [23:0] slot_width,     // Slot duration (clock cycles)
    output reg         serial_out,     // GPIO → laser/wire
    output reg         frame_done,     // Pulse when complete
    output reg         tx_active       // Transmitting flag
);

    localparam S_IDLE = 2'd0, S_SEND = 2'd1, S_GAP = 2'd2;
    
    reg [1:0]  state;
    reg [23:0] counter;
    reg [1:0]  slot_idx;       // 0..3
    reg [3:0]  pattern;        // 4-bit frame: {sync, b1, b0, idle}

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            serial_out <= 1'b0;
            frame_done <= 1'b0;
            tx_active  <= 1'b0;
            counter    <= 24'd0;
            slot_idx   <= 2'd0;
            pattern    <= 4'd0;
        end else begin
            frame_done <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    serial_out <= 1'b0;
                    tx_active  <= 1'b0;
                    if (tx_start) begin
                        pattern  <= {1'b1, qubit_in[1], qubit_in[0], 1'b0};
                        slot_idx <= 2'd0;
                        counter  <= 24'd0;
                        state    <= S_SEND;
                        tx_active <= 1'b1;
                    end
                end
                
                S_SEND: begin
                    // Output current slot bit (MSB first)
                    serial_out <= pattern[2'd3 - slot_idx];
                    
                    if (counter >= slot_width - 1) begin
                        counter <= 24'd0;
                        if (slot_idx == 2'd3) begin
                            // All 4 slots done
                            serial_out <= 1'b0;
                            state      <= S_GAP;
                        end else begin
                            slot_idx <= slot_idx + 1'b1;
                        end
                    end else begin
                        counter <= counter + 1'b1;
                    end
                end
                
                S_GAP: begin
                    // Inter-frame gap (1 slot)
                    serial_out <= 1'b0;
                    if (counter >= slot_width - 1) begin
                        frame_done <= 1'b1;
                        state      <= S_IDLE;
                        tx_active  <= 1'b0;
                    end else begin
                        counter <= counter + 1'b1;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
