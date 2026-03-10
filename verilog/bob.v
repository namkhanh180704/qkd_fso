// ============================================================
// BOB MODULE - BB84 Qubit Decoder (Receiver)
// ============================================================
module bob(
    input  wire [1:0] qubit,
    input  wire       b_prime,     // Bob's basis
    input  wire       spy_control, // 1=spy present
    output reg        a1           // Decoded data bit
);
    // Spy flips data bit (LSB), keeps basis encoding
    wire [1:0] received_qubit;
    assign received_qubit = spy_control ? {qubit[1], ~qubit[0]} : qubit;

    always @(*) begin
        case (received_qubit)
            2'b00: a1 = (b_prime == 0) ? 1'b0 : 1'b1;  // |0⟩
            2'b01: a1 = (b_prime == 0) ? 1'b1 : 1'b0;  // |1⟩
            2'b10: a1 = (b_prime == 1) ? 1'b0 : 1'b1;  // |+⟩
            2'b11: a1 = (b_prime == 1) ? 1'b1 : 1'b0;  // |-⟩
            default: a1 = 1'b0;
        endcase
    end
endmodule
