// ============================================================
// ALICE MODULE - BB84 Qubit Encoder (Transmitter)
// ============================================================
module alice(
    input  wire       a,       // Data bit
    input  wire       b,       // Basis: 0=Rectilinear, 1=Diagonal
    output wire [1:0] qubit    // Encoded qubit state
);
    // Encoding: qubit = {basis, data}
    // 00=|0⟩, 01=|1⟩, 10=|+⟩, 11=|-⟩
    assign qubit = {b, a};
endmodule
