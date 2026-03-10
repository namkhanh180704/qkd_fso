// ============================================================
// ADAPTIVE CONTROLLER — FPGA-based QKD Parameter Optimization
// ============================================================
//
// ĐÂY LÀ CORE CONTRIBUTION CỦA PAPER!
//
// Input:  QBER, SNR, photon_rate từ channel_monitor
// Output: power, basis_prob, slot_width, rep_rate
//
// 4 CHẾ ĐỘ HOẠT ĐỘNG:
//
//   AGGRESSIVE (mode=00): Channel tốt
//     → High rep rate, equal basis (50/50), narrow slots, low power
//     → Maximize key generation rate
//
//   MODERATE (mode=01): Channel trung bình
//     → Medium rate, slight basis bias (60% Z), medium slots
//     → Balance key rate vs error rate
//
//   CONSERVATIVE (mode=10): Channel xấu
//     → Low rate, strong basis bias (80% Z), wide slots, high power
//     → Prioritize reliability
//
//   PAUSE (mode=11): Deep fade / QBER quá cao
//     → Stop transmission, wait for recovery
//     → Protect key security (QBER > 11% = possible eavesdropper)
//
// ĐIỀU KIỆN CHUYỂN MODE:
//   QBER < 4% AND SNR > 180  → AGGRESSIVE
//   QBER < 8% AND SNR > 100  → MODERATE
//   QBER < 15% AND SNR > 40  → CONSERVATIVE
//   QBER ≥ 15% OR SNR ≤ 40   → PAUSE
//
// adaptive_enable: 1 = auto adjust, 0 = manual control từ switches
//
// ============================================================

module adaptive_controller (
    input  wire        clk,
    input  wire        rst_n,
    
    // Measurements from channel_monitor
    input  wire [7:0]  qber,           // 0-200 = 0%-100%
    input  wire [7:0]  snr_level,      // 0-255
    input  wire [7:0]  photon_rate,    // Qubits/window
    input  wire        window_pulse,   // Tick: new measurements ready
    
    // Control
    input  wire        adaptive_enable, // 1=auto, 0=manual
    
    // Manual overrides (when adaptive_enable=0)
    input  wire [3:0]  manual_power,
    input  wire [7:0]  manual_basis_prob,
    input  wire [23:0] manual_slot_width,
    
    // Adaptive outputs
    output reg  [3:0]  power_level,    // 0-15: PWM duty cycle cho laser
    output reg  [7:0]  basis_prob_z,   // 0-255: probability of Z basis
                                       // 128=50%, 179=70%, 204=80%
    output reg  [23:0] slot_width_out, // Clock cycles per slot
    output reg  [7:0]  rep_gap,        // Gap multiplier (1-16)
    output reg  [1:0]  mode,           // 00=aggressive, 01=moderate,
                                       // 10=conservative, 11=pause
    
    // Status
    output reg         tx_allowed,     // 0 khi PAUSE
    output reg  [7:0]  key_rate_est    // Estimated key bits/window
);

    // ============================
    // Thresholds (tunable for paper experiments)
    // ============================
    // QBER thresholds (in 0-200 scale, each unit = 0.5%)
    localparam QBER_GOOD = 8'd8;    // 4%  → safe for key generation
    localparam QBER_WARN = 8'd16;   // 8%  → channel degrading
    localparam QBER_BAD  = 8'd22;   // 11% → BB84 security limit!
    localparam QBER_CRIT = 8'd30;   // 15% → likely eavesdropper or channel failure
    
    // SNR thresholds
    localparam SNR_HIGH = 8'd180;   // Excellent channel
    localparam SNR_MED  = 8'd100;   // Acceptable
    localparam SNR_LOW  = 8'd40;    // Poor
    
    // ============================
    // Mode parameters
    // ============================
    // AGGRESSIVE: maximize throughput
    localparam [3:0]  AGG_POWER     = 4'd6;
    localparam [7:0]  AGG_BASIS     = 8'd128;      // 50% Z
    localparam [23:0] AGG_SLOT      = 24'd250000;  // 5ms = fast
    localparam [7:0]  AGG_GAP       = 8'd1;        // Minimum gap
    
    // MODERATE: balance
    localparam [3:0]  MOD_POWER     = 4'd10;
    localparam [7:0]  MOD_BASIS     = 8'd154;      // 60% Z
    localparam [23:0] MOD_SLOT      = 24'd500000;  // 10ms
    localparam [7:0]  MOD_GAP       = 8'd2;
    
    // CONSERVATIVE: reliability
    localparam [3:0]  CON_POWER     = 4'd15;       // Max power
    localparam [7:0]  CON_BASIS     = 8'd204;      // 80% Z
    localparam [23:0] CON_SLOT      = 24'd2500000; // 50ms = slow
    localparam [7:0]  CON_GAP       = 8'd4;
    
    // PAUSE
    localparam [3:0]  PAU_POWER     = 4'd15;       // Ready to resume
    localparam [7:0]  PAU_GAP       = 8'd16;       // Long wait
    
    // ============================
    // Hysteresis: prevent oscillation between modes
    // ============================
    // Require sustained improvement for 3 windows before upgrading
    reg [2:0] upgrade_counter;
    reg [1:0] target_mode;
    
    // ============================
    // Mode decision logic
    // ============================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode            <= 2'b01;       // Start MODERATE
            power_level     <= MOD_POWER;
            basis_prob_z    <= MOD_BASIS;
            slot_width_out  <= MOD_SLOT;
            rep_gap         <= MOD_GAP;
            tx_allowed      <= 1'b1;
            key_rate_est    <= 8'd0;
            upgrade_counter <= 3'd0;
            target_mode     <= 2'b01;
        end else begin
            if (!adaptive_enable) begin
                // ---- Manual mode ----
                power_level    <= manual_power;
                basis_prob_z   <= manual_basis_prob;
                slot_width_out <= manual_slot_width;
                rep_gap        <= 8'd1;
                tx_allowed     <= 1'b1;
                mode           <= 2'b01;
            end else if (window_pulse) begin
                // ---- Adaptive mode: update on each window ----
                
                // Determine target mode from measurements
                if (qber >= QBER_CRIT || snr_level <= SNR_LOW) begin
                    target_mode <= 2'b11;  // PAUSE
                end else if (qber >= QBER_WARN || snr_level < SNR_MED) begin
                    target_mode <= 2'b10;  // CONSERVATIVE
                end else if (qber < QBER_GOOD && snr_level >= SNR_HIGH) begin
                    target_mode <= 2'b00;  // AGGRESSIVE
                end else begin
                    target_mode <= 2'b01;  // MODERATE
                end
                
                // Apply mode change with hysteresis
                if (target_mode > mode) begin
                    // Downgrade: apply immediately (safety first!)
                    mode <= target_mode;
                    upgrade_counter <= 3'd0;
                end else if (target_mode < mode) begin
                    // Upgrade: require sustained improvement
                    upgrade_counter <= upgrade_counter + 1'b1;
                    if (upgrade_counter >= 3'd3) begin
                        mode <= target_mode;
                        upgrade_counter <= 3'd0;
                    end
                end else begin
                    upgrade_counter <= 3'd0;
                end
                
                // Apply parameters for current mode
                case (mode)
                    2'b00: begin  // AGGRESSIVE
                        power_level    <= AGG_POWER;
                        basis_prob_z   <= AGG_BASIS;
                        slot_width_out <= AGG_SLOT;
                        rep_gap        <= AGG_GAP;
                        tx_allowed     <= 1'b1;
                    end
                    2'b01: begin  // MODERATE
                        power_level    <= MOD_POWER;
                        basis_prob_z   <= MOD_BASIS;
                        slot_width_out <= MOD_SLOT;
                        rep_gap        <= MOD_GAP;
                        tx_allowed     <= 1'b1;
                    end
                    2'b10: begin  // CONSERVATIVE
                        power_level    <= CON_POWER;
                        basis_prob_z   <= CON_BASIS;
                        slot_width_out <= CON_SLOT;
                        rep_gap        <= CON_GAP;
                        tx_allowed     <= 1'b1;
                    end
                    2'b11: begin  // PAUSE
                        power_level    <= PAU_POWER;
                        rep_gap        <= PAU_GAP;
                        tx_allowed     <= 1'b0;
                        
                        // During pause: keep checking if channel recovers
                        // Send probe pulses with conservative settings
                        if (snr_level > SNR_MED) begin
                            tx_allowed <= 1'b1;  // Try a few
                        end
                    end
                endcase
                
                // Estimate key rate
                // key_rate ≈ sifted_rate × (1 - 2×QBER) × basis_efficiency
                // Simplified: just use photon_rate adjusted by mode
                case (mode)
                    2'b00: key_rate_est <= photon_rate >> 1;  // ~50% of received
                    2'b01: key_rate_est <= photon_rate >> 2;  // ~25%
                    2'b10: key_rate_est <= photon_rate >> 3;  // ~12%
                    2'b11: key_rate_est <= 8'd0;              // Paused
                endcase
            end
        end
    end

endmodule
