// ============================================================
// TRNG WRAPPER — Drop-in replacement for lfsr_random
// ============================================================
//
// Bao bọc trng.v với interface tương thích lfsr_random:
//   - random_bit: 1-bit output (truly random)
//   - random_byte: 8-bit output (truly random)
//   - enable: advance signal (latch new values)
//
// TRNG chạy liên tục, tích lũy bits vào shift register.
// Khi enable pulse, giá trị hiện tại được latch ra output.
//
// Throughput: TRNG tạo ~97k bits/s (>> 200 bits/s cần cho BB84)
// → Luôn có đủ entropy sẵn sàng.
//
// SEED parameter giữ lại cho backward compatibility nhưng
// không sử dụng (TRNG không cần seed).
// ============================================================

module trng_random #(
    parameter SEED = 16'h0000   // Unused, kept for compatibility
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    output reg         random_bit,
    output reg  [7:0]  random_byte
);

    // ============================================================
    // Internal TRNG instance
    // ============================================================
    wire       trng_bit, trng_bit_valid;
    wire [7:0] trng_byte;
    wire       trng_byte_valid;
    
    trng #(.NUM_RO(4)) trng_core (
        .clk(clk),
        .rst_n(rst_n),
        .enable(1'b1),              // Always running
        .random_bit(trng_bit),
        .random_byte(trng_byte),
        .bit_valid(trng_bit_valid),
        .byte_valid(trng_byte_valid)
    );
    
    // ============================================================
    // Bit accumulator (continuously filled by TRNG)
    // ============================================================
    reg [7:0]  bit_shift;       // Shift register for bits
    reg        latest_bit;      // Most recent debiased bit
    reg [7:0]  latest_byte;     // Most recent complete byte
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_shift   <= 8'hA5;   // Non-zero init
            latest_bit  <= 1'b0;
            latest_byte <= 8'hA5;
        end else begin
            // Continuously accumulate TRNG output
            if (trng_bit_valid) begin
                bit_shift  <= {bit_shift[6:0], trng_bit};
                latest_bit <= trng_bit;
            end
            if (trng_byte_valid) begin
                latest_byte <= trng_byte;
            end
        end
    end
    
    // ============================================================
    // Output latch (update on enable, same as LFSR interface)
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            random_bit  <= 1'b0;
            random_byte <= 8'h00;
        end else if (enable) begin
            random_bit  <= latest_bit;
            random_byte <= latest_byte;
        end
    end

endmodule
