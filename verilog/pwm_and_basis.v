// ============================================================
// PWM POWER CONTROLLER — Điều chỉnh công suất laser
// ============================================================
// power_level[3:0] = 0-15 → PWM duty cycle 0%-100%
// Frequency: ~50kHz (đủ nhanh, laser không nhấp nháy)
//
// Dùng với transistor: PWM → Base → Collector drives laser
// Duty cycle cao = laser sáng hơn = tín hiệu mạnh hơn
// ============================================================

module pwm_power (
    input  wire        clk,        // 50MHz
    input  wire        rst_n,
    input  wire [3:0]  power_level, // 0-15
    input  wire        signal_in,   // Original TX signal
    output wire        signal_out   // Power-modulated signal
);
    // PWM counter: 10-bit → 50MHz/1024 ≈ 49kHz
    reg [9:0] pwm_cnt;
    wire [9:0] threshold = {power_level, 6'b111111}; // Scale 0-15 → 0-1023
    wire pwm_high = (pwm_cnt < threshold);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pwm_cnt <= 10'd0;
        else
            pwm_cnt <= pwm_cnt + 1'b1;
    end
    
    // Output: signal AND pwm (laser ON chỉ khi cả hai HIGH)
    // Khi power_level = 15: pwm_high luôn = 1 → signal_out = signal_in
    // Khi power_level = 0:  pwm_high luôn = 0 → signal_out = 0
    assign signal_out = signal_in & pwm_high;

endmodule


// ============================================================
// BIASED BASIS SELECTOR — Adjustable basis probability
// ============================================================
// Thay vì 50/50 cố định, cho phép bias sang Z-basis
// basis_prob_z[7:0]: 0-255
//   128 = 50% Z (equal)
//   179 = 70% Z
//   204 = 80% Z
//   230 = 90% Z
//
// So sánh LFSR output với threshold → chọn basis
// ============================================================

module biased_basis_selector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,        // Pulse: generate new basis
    input  wire [7:0]  basis_prob_z,  // Z-basis probability threshold
    input  wire        random_bit_0,  // From LFSR bit 0
    input  wire        random_bit_1,  // From LFSR bit 1  
    input  wire        random_bit_2,  // From LFSR bit 2
    input  wire        random_bit_3,  // From LFSR bit 3
    input  wire        random_bit_4,
    input  wire        random_bit_5,
    input  wire        random_bit_6,
    input  wire        random_bit_7,
    output reg         basis_out      // 0=Rect(Z), 1=Diag(X)
);
    wire [7:0] rand_byte = {random_bit_7, random_bit_6, random_bit_5, random_bit_4,
                             random_bit_3, random_bit_2, random_bit_1, random_bit_0};
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            basis_out <= 1'b0;
        else if (enable) begin
            // rand_byte < basis_prob_z → choose Z (rect) basis = 0
            // rand_byte >= basis_prob_z → choose X (diag) basis = 1
            basis_out <= (rand_byte >= basis_prob_z) ? 1'b1 : 1'b0;
        end
    end

endmodule
