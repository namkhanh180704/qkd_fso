// ============================================================
// ERROR ESTIMATION - Eavesdropping Detection
// ============================================================
module error_estimation(
    input  wire a,           // Alice's original data
    input  wire a1,          // Bob's decoded data
    input  wire b,           // Alice's basis
    input  wire b_prime,     // Bob's basis
    output wire match,       // Data match (A == A')
    output wire basis_match, // Basis match (B == B')
    output wire spy_detect   // Spy detected
);
    assign match       = ~(a ^ a1);        // XNOR: 1 if equal
    assign basis_match = ~(b ^ b_prime);   // XNOR: 1 if equal
    assign spy_detect  = basis_match & ~match; // Basis match but data wrong
endmodule
