// ============================================================
// GAMMA-GAMMA ATMOSPHERIC TURBULENCE CHANNEL EMULATOR
// ============================================================
//
// MÔ HÌNH VẬT LÝ:
//   Irradiance I = X × Y (two-scale multiplicative fading)
//
//   X ~ Gamma(α, 1/α) : Large-scale turbulence (slow eddies)
//   Y ~ Gamma(β, 1/β) : Small-scale turbulence (fast scintillation)
//
//   Scale: 128 = mean irradiance (I/I₀ = 1.0)
//   Combined I = (X × Y) >> 7 (normalized, uses embedded multiplier)
//
// THAM SỐ MÔ HÌNH (Al-Habash / Andrews / Phillips, 2001):
//   α, β computed from Rytov variance σ²_R:
//     α = [exp(0.49σ²_R / (1 + 1.11σ_R^{12/5})^{7/6}) - 1]^{-1}
//     β = [exp(0.51σ²_R / (1 + 0.69σ_R^{12/5})^{5/6}) - 1]^{-1}
//
//   σ²_R = 1.23 × C²_n × k^{7/6} × L^{11/6}
//   (C²_n = refractive index structure, k = 2π/λ, L = distance)
//
// TURBULENCE LEVELS → Rytov variance mapping:
//   Level 0: OFF      (σ²_R = 0,   bypass)
//   Level 1: WEAK     (σ²_R = 0.2, α=11.65, β=10.12, σ²_I=0.19)
//   Level 2: MILD     (σ²_R = 0.5, α=5.98,  β=4.40,  σ²_I=0.43)
//   Level 3: MODERATE (σ²_R = 1.2, α=4.20,  β=2.27,  σ²_I=0.78)
//   Level 4: STRONG   (σ²_R = 3.0, α=4.12,  β=1.44,  σ²_I=1.11)
//   Level 5: SEVERE   (σ²_R = 8.0, α=5.27,  β=1.13,  σ²_I=1.24)
//
// CHANNEL EFFECTS (derived from irradiance I):
//   1. DEEP FADE:     I < threshold → signal = 0
//   2. SCINTILLATION: I < threshold → probabilistic blanking
//   3. BIT FLIP:      flip_prob ∝ 1/I (weaker signal → more errors)
//   4. DYNAMIC:       turb_level random walk ±1
//
// TRIỂN KHAI FPGA:
//   ROM-based inverse CDF: 256×8-bit LUT per (α or β) per level
//   Total ROM: 2 × 5 × 256 × 8 = 20,480 bits (5 M4K blocks)
//   1 embedded 8×8 multiplier for I = X × Y
//   Estimated: ~800 LEs + 5 M4K + 1 multiplier
//
// THAM KHẢO:
//   [1] Al-Habash, Andrews, Phillips, "Mathematical model for the
//       irradiance PDF of a laser beam propagating through turbulent
//       media," Optical Engineering 40(8), 2001.
//   [2] Andrews & Phillips, "Laser Beam Propagation through Random
//       Media," 2nd ed., SPIE Press, 2005.
//
// PORT INTERFACE: Compatible with turbulence_emulator.v (drop-in)
// ============================================================

module gamma_gamma_channel (
    input  wire        clk,
    input  wire        rst_n,
    
    // Signal path
    input  wire        signal_in,       // Clean TX signal
    output wire        signal_out,      // Faded/noisy signal
    
    // Control (same as turbulence_emulator)
    input  wire        turb_enable,     // 1=ON, 0=bypass
    input  wire [2:0]  turb_level,      // 0-5 turbulence strength
    input  wire        dynamic_enable,  // Auto-vary level ±1
    
    // Status outputs (compatible with turbulence_emulator)
    output reg  [2:0]  current_level,   // Effective level
    output reg         fade_active,     // In deep fade
    output reg         scint_active,    // Scintillation blanking
    output reg  [7:0]  flip_count,      // Bit flips injected
    output reg  [7:0]  fade_count,      // Fade events
    
    // [v2] Per-qubit sample trigger
    input  wire        sample_en,

    // NEW: Gamma-Gamma specific outputs (for UART reporting)
    output reg  [7:0]  irradiance_x,    // Large-scale sample
    output reg  [7:0]  irradiance_y,    // Small-scale sample
    output reg  [7:0]  irradiance_combined // Combined I (128=mean)
);

    // ============================================================
    // 1. LFSR RANDOM GENERATORS (4 independent sources)
    // ============================================================
    
    // LFSR-1: Large-scale ROM address (32-bit, long period)
    reg [31:0] lfsr_large;
    wire fb_large = lfsr_large[31] ^ lfsr_large[21] ^ lfsr_large[1] ^ lfsr_large[0];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr_large <= 32'hDEAD_BEEF;
        else
            lfsr_large <= {lfsr_large[30:0], fb_large};
    end
    
    // LFSR-2: Small-scale ROM address (32-bit, different seed)
    reg [31:0] lfsr_small;
    wire fb_small = lfsr_small[31] ^ lfsr_small[28] ^ lfsr_small[19] ^ lfsr_small[0];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr_small <= 32'hCAFE_1337;
        else
            lfsr_small <= {lfsr_small[30:0], fb_small};
    end
    
    // LFSR-3: Bit flip decisions (16-bit, fast)
    reg [15:0] lfsr_flip;
    wire fb_flip = lfsr_flip[15] ^ lfsr_flip[14] ^ lfsr_flip[12] ^ lfsr_flip[3];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr_flip <= 16'hA5A5;
        else
            lfsr_flip <= {lfsr_flip[14:0], fb_flip};
    end
    
    // LFSR-4: Dynamic level variation (20-bit, slow advance)
    reg [19:0] lfsr_dyn;
    wire fb_dyn = lfsr_dyn[19] ^ lfsr_dyn[18] ^ lfsr_dyn[17] ^ lfsr_dyn[13];
    reg [23:0] dyn_divider;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_dyn    <= 20'hB7E37;
            dyn_divider <= 24'd0;
        end else begin
            dyn_divider <= dyn_divider + 1'b1;
            if (dyn_divider == 24'd0)
                lfsr_dyn <= {lfsr_dyn[18:0], fb_dyn};
        end
    end

    // LFSR-5: [FIX v2] Random bit source cho fade/scintillation output
    // Thay vì output 1'b0 khi fade, dùng bit ngẫu nhiên này (như Python)
    reg [7:0] lfsr_fade_rand;
    wire fb_fade = lfsr_fade_rand[7] ^ lfsr_fade_rand[5] ^ lfsr_fade_rand[4] ^ lfsr_fade_rand[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr_fade_rand <= 8'hF3;
        else
            lfsr_fade_rand <= {lfsr_fade_rand[6:0], fb_fade};
    end
    
    // ============================================================
    // 2. DYNAMIC TURBULENCE LEVEL (random walk ±1)
    // ============================================================
    
    reg [25:0] dynamic_timer;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dynamic_timer <= 26'd0;
            current_level <= 3'd0;
        end else begin
            dynamic_timer <= dynamic_timer + 1'b1;
            
            if (!turb_enable) begin
                current_level <= 3'd0;
            end else if (dynamic_timer == 26'd0 && dynamic_enable) begin
                // Random walk every ~1.3 seconds
                case (lfsr_dyn[1:0])
                    2'b00: current_level <= turb_level;                                     // Stay
                    2'b01: current_level <= (turb_level < 3'd5) ? turb_level + 1'b1 : 3'd5; // +1
                    2'b10: current_level <= (turb_level > 3'd0) ? turb_level - 1'b1 : 3'd0; // -1
                    2'b11: current_level <= turb_level;                                     // Stay
                endcase
            end else if (!dynamic_enable) begin
                current_level <= turb_level;
            end
        end
    end

    // ============================================================
    // 3. LARGE-SCALE FADING (slow atmospheric eddies)
    // ============================================================
    // Update period: ~0.3s (weak) to ~2s (severe)
    // Models large convective cells drifting across beam path
    
    reg [26:0] large_timer;
    reg [7:0]  x_sample;    // Current large-scale irradiance
    
    // Update period depends on turbulence level
    reg [26:0] large_period;
    always @(*) begin
        case (current_level)
            3'd0:    large_period = 27'd100_000_000;  // 2.0s (unused in bypass)
            3'd1:    large_period = 27'd100_000_000;  // 2.0s — weak: slow variation
            3'd2:    large_period = 27'd75_000_000;   // 1.5s
            3'd3:    large_period = 27'd50_000_000;   // 1.0s
            3'd4:    large_period = 27'd30_000_000;   // 0.6s
            3'd5:    large_period = 27'd15_000_000;   // 0.3s — severe: rapid changes
            default: large_period = 27'd50_000_000;
        endcase
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            large_timer <= 27'd0;
            x_sample    <= 8'd128;  // Start at mean
        end else if (!turb_enable) begin
            x_sample    <= 8'd128;
            large_timer <= 27'd0;
        end else if (sample_en) begin
            // [FIX v2] Resample X mỗi qubit (như Python: x1 = np.random.gamma() mỗi lần)
            x_sample    <= alpha_rom(current_level, lfsr_large[7:0]);
            large_timer <= 27'd0;
        end else begin
            large_timer <= large_timer + 1'b1;
            if (large_timer >= large_period) begin
                large_timer <= 27'd0;
                // Sample from alpha ROM using LFSR as address
                x_sample <= alpha_rom(current_level, lfsr_large[7:0]);
            end
        end
    end
    
    // ============================================================
    // 4. SMALL-SCALE FADING (fast scintillation)
    // ============================================================
    // Update period: ~5ms (weak) to ~0.1ms (severe)
    // Models rapid intensity fluctuations
    
    reg [22:0] small_timer;
    reg [7:0]  y_sample;    // Current small-scale irradiance
    
    reg [22:0] small_period;
    always @(*) begin
        case (current_level)
            3'd0:    small_period = 23'd5_000_000;  // 100ms (unused)
            3'd1:    small_period = 23'd5_000_000;  // 100ms — weak: slow scintillation
            3'd2:    small_period = 23'd2_500_000;  // 50ms
            3'd3:    small_period = 23'd1_000_000;  // 20ms
            3'd4:    small_period = 23'd500_000;    // 10ms
            3'd5:    small_period = 23'd250_000;    // 5ms — severe: rapid scintillation
            default: small_period = 23'd1_000_000;
        endcase
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            small_timer <= 23'd0;
            y_sample    <= 8'd128;
        end else if (!turb_enable) begin
            y_sample    <= 8'd128;
            small_timer <= 23'd0;
        end else if (sample_en) begin
            // [FIX v2] Resample Y mỗi qubit (như Python: x2 = np.random.gamma() mỗi lần)
            y_sample    <= beta_rom(current_level, lfsr_small[7:0]);
            small_timer <= 23'd0;
        end else begin
            small_timer <= small_timer + 1'b1;
            if (small_timer >= small_period) begin
                small_timer <= 23'd0;
                y_sample <= beta_rom(current_level, lfsr_small[7:0]);
            end
        end
    end
    
    // ============================================================
    // 5. IRRADIANCE COMPUTATION (I = X × Y / 128)
    // ============================================================
    // Uses Cyclone II embedded 9×9 multiplier
    // X, Y ∈ [0, 255], mean = 128
    // I = X × Y >> 7  →  I ∈ [0, ~510], mean ≈ 128
    
    wire [15:0] xy_product = x_sample * y_sample;  // 8×8 → 16-bit
    wire [8:0]  i_norm = xy_product[15:7];          // >> 7, 9-bit result
    wire [7:0]  i_clamp = (i_norm > 9'd255) ? 8'd255 : i_norm[7:0];
    
    // Register irradiance outputs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irradiance_x <= 8'd128;
            irradiance_y <= 8'd128;
            irradiance_combined <= 8'd128;
        end else begin
            irradiance_x <= x_sample;
            irradiance_y <= y_sample;
            irradiance_combined <= turb_enable ? i_clamp : 8'd128;
        end
    end
    
    // ============================================================
    // 6. CHANNEL EFFECTS FROM IRRADIANCE
    // ============================================================
    
    // --- 6a. DEEP FADE ---
    // When irradiance drops below threshold: complete signal loss
    // Threshold scales with turbulence level
    reg [7:0] deep_fade_thresh;
    always @(*) begin
        case (current_level)
            // [MATCH PYTHON] threshold = 0.3 × mean(128) = 38.4
            // Python: if fading < 0.3 → random bit (mean fading = 1.0)
            3'd0:    deep_fade_thresh = 8'd0;    // OFF
            3'd1:    deep_fade_thresh = 8'd38;   // 0.3 × 128 (match Python)
            3'd2:    deep_fade_thresh = 8'd38;   // 0.3 × 128 (match Python)
            3'd3:    deep_fade_thresh = 8'd38;   // 0.3 × 128 (match Python)
            3'd4:    deep_fade_thresh = 8'd38;   // 0.3 × 128 (match Python)
            3'd5:    deep_fade_thresh = 8'd38;   // 0.3 × 128 (match Python)
            default: deep_fade_thresh = 8'd0;
        endcase
    end
    
    wire in_deep_fade = turb_enable && (i_clamp < deep_fade_thresh);
    
    // Fade event counter
    reg prev_fade;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fade_active <= 1'b0;
            fade_count  <= 8'd0;
            prev_fade   <= 1'b0;
        end else begin
            fade_active <= in_deep_fade;
            prev_fade   <= in_deep_fade;
            // Count rising edges of fade (new fade events)
            if (in_deep_fade && !prev_fade)
                fade_count <= fade_count + 1'b1;
        end
    end
    
    // --- 6b. SCINTILLATION ---
    // When irradiance is low but not deep fade: intermittent blanking
    // Uses LFSR for probabilistic blanking within scintillation zone
    // [MATCH PYTHON v3] scint_thresh = 0 → tắt scintillation blanking
    // Python không có cơ chế này → tắt để FPGA khớp Python
    reg [7:0] scint_thresh;
    always @(*) begin
        scint_thresh = 8'd0;  // Disabled: match Python model
    end
    
    // Scintillation probability: higher when irradiance is lower
    // P(blank) = (scint_thresh - I) / scint_thresh (approximately)
    wire in_scint_zone = turb_enable && !in_deep_fade && (i_clamp < scint_thresh);
    wire [7:0] scint_prob = scint_thresh - i_clamp;  // Higher when I is lower
    wire scint_blank = in_scint_zone && (lfsr_flip[7:0] < scint_prob);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            scint_active <= 1'b0;
        else
            scint_active <= scint_blank;
    end
    
    // --- 6c. BIT FLIP (BER ∝ 1/I) ---
    // Physical basis: lower irradiance → weaker SNR → higher BER
    // Model: flip_probability = base_rate × (128 / I)
    // Implementation: compare LFSR against threshold derived from I
    
    // [MATCH PYTHON v3] do_flip = 0 → chỉ deep_fade gây lỗi ngẫu nhiên
    // Python model: nếu fading < threshold → random bit, còn lại truyền hoàn hảo
    // Verilog gốc có thêm BER theo irradiance (do_flip) → QBER ~40% vs Python ~3%
    // Tắt do_flip để kết quả FPGA khớp Python simulation
    reg [7:0] flip_threshold;
    always @(*) begin
        flip_threshold = 8'd0;  // Disabled: match Python clean-outside-fade model
    end
    
    wire do_flip = turb_enable && (lfsr_flip[15:8] < flip_threshold);
    wire flipped_signal = signal_in ^ do_flip;
    
    // Flip counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            flip_count <= 8'd0;
        else if (do_flip)
            flip_count <= flip_count + 1'b1;
    end

    // ============================================================
    // 7. OUTPUT COMBINE
    // ============================================================
    // Priority: deep_fade > scintillation > bit_flip > clean
    //
    // [FIX v2]: fade/scint → random bit (thay vì 1'b0)
    // Python: if fading < threshold → return random.choice(['0','1'])
    // Verilog gốc sai: luôn output 0 → QBER sai hệ thống
    
    reg signal_out_reg;
    
    always @(*) begin
        if (!turb_enable)
            signal_out_reg = signal_in;           // Bypass
        else if (in_deep_fade)
            signal_out_reg = lfsr_fade_rand[0];   // [FIX] Random bit (như Python)
        else if (scint_blank)
            signal_out_reg = lfsr_fade_rand[1];   // [FIX] Random bit (scintillation)
        else
            signal_out_reg = flipped_signal;      // Normal with possible bit flip
    end
    
    assign signal_out = signal_out_reg;

    // ============================================================
    // 8. ROM FUNCTIONS (generated by gamma_gamma_lut_gen.py)
    // ============================================================
    // Inverse CDF of Gamma(α, 1/α) distribution
    // 256 entries per level, 8-bit output
    // 128 = mean irradiance (I/I₀ = 1.0)
    //
    // To regenerate:
    //   python3 gamma_gamma_lut_gen.py
    //   → gamma_gamma_rom.v (copy functions here)
    
    // -------- Include generated ROM data below --------

// ============================================================
// AUTO-GENERATED: Gamma-Gamma Channel ROM Data
// Generated by gamma_gamma_lut_gen.py
// DO NOT EDIT MANUALLY
// ============================================================
// Physical model: I = X * Y
//   X ~ Gamma(alpha, 1/alpha), Y ~ Gamma(beta, 1/beta)
//   Scale: 128 = mean irradiance (I/I0 = 1.0)
//
// Level 1 (WEAK): alpha=11.651, beta=10.122, sI2=0.1931
// Level 2 (MILD): alpha=5.978, beta=4.398, sI2=0.4327
// Level 3 (MODERATE): alpha=4.198, beta=2.269, sI2=0.7838
// Level 4 (STRONG): alpha=4.120, beta=1.435, sI2=1.1087
// Level 5 (SEVERE): alpha=5.272, beta=1.134, sI2=1.2392
// ============================================================

// Large-scale fading ROM
function [7:0] alpha_rom;
    input [2:0] level;
    input [7:0] addr;
begin
    case (level)
        3'd1: case (addr)
            8'd0:alpha_rom=8'd45; 8'd1:alpha_rom=8'd53; 8'd2:alpha_rom=8'd56; 8'd3:alpha_rom=8'd59; 8'd4:alpha_rom=8'd61; 8'd5:alpha_rom=8'd63; 8'd6:alpha_rom=8'd65; 8'd7:alpha_rom=8'd67;
            8'd8:alpha_rom=8'd68; 8'd9:alpha_rom=8'd69; 8'd10:alpha_rom=8'd70; 8'd11:alpha_rom=8'd71; 8'd12:alpha_rom=8'd72; 8'd13:alpha_rom=8'd73; 8'd14:alpha_rom=8'd74; 8'd15:alpha_rom=8'd75;
            8'd16:alpha_rom=8'd76; 8'd17:alpha_rom=8'd77; 8'd18:alpha_rom=8'd78; 8'd19:alpha_rom=8'd78; 8'd20:alpha_rom=8'd79; 8'd21:alpha_rom=8'd80; 8'd22:alpha_rom=8'd80; 8'd23:alpha_rom=8'd81;
            8'd24:alpha_rom=8'd82; 8'd25:alpha_rom=8'd82; 8'd26:alpha_rom=8'd83; 8'd27:alpha_rom=8'd84; 8'd28:alpha_rom=8'd84; 8'd29:alpha_rom=8'd85; 8'd30:alpha_rom=8'd85; 8'd31:alpha_rom=8'd86;
            8'd32:alpha_rom=8'd86; 8'd33:alpha_rom=8'd87; 8'd34:alpha_rom=8'd87; 8'd35:alpha_rom=8'd88; 8'd36:alpha_rom=8'd89; 8'd37:alpha_rom=8'd89; 8'd38:alpha_rom=8'd90; 8'd39:alpha_rom=8'd90;
            8'd40:alpha_rom=8'd90; 8'd41:alpha_rom=8'd91; 8'd42:alpha_rom=8'd91; 8'd43:alpha_rom=8'd92; 8'd44:alpha_rom=8'd92; 8'd45:alpha_rom=8'd93; 8'd46:alpha_rom=8'd93; 8'd47:alpha_rom=8'd94;
            8'd48:alpha_rom=8'd94; 8'd49:alpha_rom=8'd95; 8'd50:alpha_rom=8'd95; 8'd51:alpha_rom=8'd95; 8'd52:alpha_rom=8'd96; 8'd53:alpha_rom=8'd96; 8'd54:alpha_rom=8'd97; 8'd55:alpha_rom=8'd97;
            8'd56:alpha_rom=8'd98; 8'd57:alpha_rom=8'd98; 8'd58:alpha_rom=8'd98; 8'd59:alpha_rom=8'd99; 8'd60:alpha_rom=8'd99; 8'd61:alpha_rom=8'd100; 8'd62:alpha_rom=8'd100; 8'd63:alpha_rom=8'd100;
            8'd64:alpha_rom=8'd101; 8'd65:alpha_rom=8'd101; 8'd66:alpha_rom=8'd102; 8'd67:alpha_rom=8'd102; 8'd68:alpha_rom=8'd102; 8'd69:alpha_rom=8'd103; 8'd70:alpha_rom=8'd103; 8'd71:alpha_rom=8'd104;
            8'd72:alpha_rom=8'd104; 8'd73:alpha_rom=8'd104; 8'd74:alpha_rom=8'd105; 8'd75:alpha_rom=8'd105; 8'd76:alpha_rom=8'd105; 8'd77:alpha_rom=8'd106; 8'd78:alpha_rom=8'd106; 8'd79:alpha_rom=8'd107;
            8'd80:alpha_rom=8'd107; 8'd81:alpha_rom=8'd107; 8'd82:alpha_rom=8'd108; 8'd83:alpha_rom=8'd108; 8'd84:alpha_rom=8'd108; 8'd85:alpha_rom=8'd109; 8'd86:alpha_rom=8'd109; 8'd87:alpha_rom=8'd109;
            8'd88:alpha_rom=8'd110; 8'd89:alpha_rom=8'd110; 8'd90:alpha_rom=8'd111; 8'd91:alpha_rom=8'd111; 8'd92:alpha_rom=8'd111; 8'd93:alpha_rom=8'd112; 8'd94:alpha_rom=8'd112; 8'd95:alpha_rom=8'd112;
            8'd96:alpha_rom=8'd113; 8'd97:alpha_rom=8'd113; 8'd98:alpha_rom=8'd113; 8'd99:alpha_rom=8'd114; 8'd100:alpha_rom=8'd114; 8'd101:alpha_rom=8'd114; 8'd102:alpha_rom=8'd115; 8'd103:alpha_rom=8'd115;
            8'd104:alpha_rom=8'd115; 8'd105:alpha_rom=8'd116; 8'd106:alpha_rom=8'd116; 8'd107:alpha_rom=8'd117; 8'd108:alpha_rom=8'd117; 8'd109:alpha_rom=8'd117; 8'd110:alpha_rom=8'd118; 8'd111:alpha_rom=8'd118;
            8'd112:alpha_rom=8'd118; 8'd113:alpha_rom=8'd119; 8'd114:alpha_rom=8'd119; 8'd115:alpha_rom=8'd119; 8'd116:alpha_rom=8'd120; 8'd117:alpha_rom=8'd120; 8'd118:alpha_rom=8'd120; 8'd119:alpha_rom=8'd121;
            8'd120:alpha_rom=8'd121; 8'd121:alpha_rom=8'd122; 8'd122:alpha_rom=8'd122; 8'd123:alpha_rom=8'd122; 8'd124:alpha_rom=8'd123; 8'd125:alpha_rom=8'd123; 8'd126:alpha_rom=8'd123; 8'd127:alpha_rom=8'd124;
            8'd128:alpha_rom=8'd124; 8'd129:alpha_rom=8'd124; 8'd130:alpha_rom=8'd125; 8'd131:alpha_rom=8'd125; 8'd132:alpha_rom=8'd125; 8'd133:alpha_rom=8'd126; 8'd134:alpha_rom=8'd126; 8'd135:alpha_rom=8'd127;
            8'd136:alpha_rom=8'd127; 8'd137:alpha_rom=8'd127; 8'd138:alpha_rom=8'd128; 8'd139:alpha_rom=8'd128; 8'd140:alpha_rom=8'd128; 8'd141:alpha_rom=8'd129; 8'd142:alpha_rom=8'd129; 8'd143:alpha_rom=8'd130;
            8'd144:alpha_rom=8'd130; 8'd145:alpha_rom=8'd130; 8'd146:alpha_rom=8'd131; 8'd147:alpha_rom=8'd131; 8'd148:alpha_rom=8'd131; 8'd149:alpha_rom=8'd132; 8'd150:alpha_rom=8'd132; 8'd151:alpha_rom=8'd133;
            8'd152:alpha_rom=8'd133; 8'd153:alpha_rom=8'd133; 8'd154:alpha_rom=8'd134; 8'd155:alpha_rom=8'd134; 8'd156:alpha_rom=8'd135; 8'd157:alpha_rom=8'd135; 8'd158:alpha_rom=8'd135; 8'd159:alpha_rom=8'd136;
            8'd160:alpha_rom=8'd136; 8'd161:alpha_rom=8'd137; 8'd162:alpha_rom=8'd137; 8'd163:alpha_rom=8'd137; 8'd164:alpha_rom=8'd138; 8'd165:alpha_rom=8'd138; 8'd166:alpha_rom=8'd139; 8'd167:alpha_rom=8'd139;
            8'd168:alpha_rom=8'd139; 8'd169:alpha_rom=8'd140; 8'd170:alpha_rom=8'd140; 8'd171:alpha_rom=8'd141; 8'd172:alpha_rom=8'd141; 8'd173:alpha_rom=8'd142; 8'd174:alpha_rom=8'd142; 8'd175:alpha_rom=8'd143;
            8'd176:alpha_rom=8'd143; 8'd177:alpha_rom=8'd143; 8'd178:alpha_rom=8'd144; 8'd179:alpha_rom=8'd144; 8'd180:alpha_rom=8'd145; 8'd181:alpha_rom=8'd145; 8'd182:alpha_rom=8'd146; 8'd183:alpha_rom=8'd146;
            8'd184:alpha_rom=8'd147; 8'd185:alpha_rom=8'd147; 8'd186:alpha_rom=8'd148; 8'd187:alpha_rom=8'd148; 8'd188:alpha_rom=8'd149; 8'd189:alpha_rom=8'd149; 8'd190:alpha_rom=8'd150; 8'd191:alpha_rom=8'd150;
            8'd192:alpha_rom=8'd151; 8'd193:alpha_rom=8'd151; 8'd194:alpha_rom=8'd152; 8'd195:alpha_rom=8'd152; 8'd196:alpha_rom=8'd153; 8'd197:alpha_rom=8'd153; 8'd198:alpha_rom=8'd154; 8'd199:alpha_rom=8'd154;
            8'd200:alpha_rom=8'd155; 8'd201:alpha_rom=8'd156; 8'd202:alpha_rom=8'd156; 8'd203:alpha_rom=8'd157; 8'd204:alpha_rom=8'd157; 8'd205:alpha_rom=8'd158; 8'd206:alpha_rom=8'd159; 8'd207:alpha_rom=8'd159;
            8'd208:alpha_rom=8'd160; 8'd209:alpha_rom=8'd160; 8'd210:alpha_rom=8'd161; 8'd211:alpha_rom=8'd162; 8'd212:alpha_rom=8'd162; 8'd213:alpha_rom=8'd163; 8'd214:alpha_rom=8'd164; 8'd215:alpha_rom=8'd165;
            8'd216:alpha_rom=8'd165; 8'd217:alpha_rom=8'd166; 8'd218:alpha_rom=8'd167; 8'd219:alpha_rom=8'd168; 8'd220:alpha_rom=8'd168; 8'd221:alpha_rom=8'd169; 8'd222:alpha_rom=8'd170; 8'd223:alpha_rom=8'd171;
            8'd224:alpha_rom=8'd172; 8'd225:alpha_rom=8'd173; 8'd226:alpha_rom=8'd173; 8'd227:alpha_rom=8'd174; 8'd228:alpha_rom=8'd175; 8'd229:alpha_rom=8'd176; 8'd230:alpha_rom=8'd177; 8'd231:alpha_rom=8'd178;
            8'd232:alpha_rom=8'd180; 8'd233:alpha_rom=8'd181; 8'd234:alpha_rom=8'd182; 8'd235:alpha_rom=8'd183; 8'd236:alpha_rom=8'd184; 8'd237:alpha_rom=8'd186; 8'd238:alpha_rom=8'd187; 8'd239:alpha_rom=8'd189;
            8'd240:alpha_rom=8'd190; 8'd241:alpha_rom=8'd192; 8'd242:alpha_rom=8'd193; 8'd243:alpha_rom=8'd195; 8'd244:alpha_rom=8'd197; 8'd245:alpha_rom=8'd199; 8'd246:alpha_rom=8'd202; 8'd247:alpha_rom=8'd204;
            8'd248:alpha_rom=8'd207; 8'd249:alpha_rom=8'd210; 8'd250:alpha_rom=8'd214; 8'd251:alpha_rom=8'd219; 8'd252:alpha_rom=8'd224; 8'd253:alpha_rom=8'd231; 8'd254:alpha_rom=8'd241; 8'd255:alpha_rom=8'd255;
            default: alpha_rom = 8'd128;
        endcase
        3'd2: case (addr)
            8'd0:alpha_rom=8'd26; 8'd1:alpha_rom=8'd33; 8'd2:alpha_rom=8'd37; 8'd3:alpha_rom=8'd40; 8'd4:alpha_rom=8'd43; 8'd5:alpha_rom=8'd45; 8'd6:alpha_rom=8'd47; 8'd7:alpha_rom=8'd48;
            8'd8:alpha_rom=8'd50; 8'd9:alpha_rom=8'd51; 8'd10:alpha_rom=8'd52; 8'd11:alpha_rom=8'd54; 8'd12:alpha_rom=8'd55; 8'd13:alpha_rom=8'd56; 8'd14:alpha_rom=8'd57; 8'd15:alpha_rom=8'd58;
            8'd16:alpha_rom=8'd59; 8'd17:alpha_rom=8'd60; 8'd18:alpha_rom=8'd61; 8'd19:alpha_rom=8'd62; 8'd20:alpha_rom=8'd63; 8'd21:alpha_rom=8'd63; 8'd22:alpha_rom=8'd64; 8'd23:alpha_rom=8'd65;
            8'd24:alpha_rom=8'd66; 8'd25:alpha_rom=8'd67; 8'd26:alpha_rom=8'd67; 8'd27:alpha_rom=8'd68; 8'd28:alpha_rom=8'd69; 8'd29:alpha_rom=8'd69; 8'd30:alpha_rom=8'd70; 8'd31:alpha_rom=8'd71;
            8'd32:alpha_rom=8'd72; 8'd33:alpha_rom=8'd72; 8'd34:alpha_rom=8'd73; 8'd35:alpha_rom=8'd73; 8'd36:alpha_rom=8'd74; 8'd37:alpha_rom=8'd75; 8'd38:alpha_rom=8'd75; 8'd39:alpha_rom=8'd76;
            8'd40:alpha_rom=8'd77; 8'd41:alpha_rom=8'd77; 8'd42:alpha_rom=8'd78; 8'd43:alpha_rom=8'd78; 8'd44:alpha_rom=8'd79; 8'd45:alpha_rom=8'd80; 8'd46:alpha_rom=8'd80; 8'd47:alpha_rom=8'd81;
            8'd48:alpha_rom=8'd81; 8'd49:alpha_rom=8'd82; 8'd50:alpha_rom=8'd82; 8'd51:alpha_rom=8'd83; 8'd52:alpha_rom=8'd83; 8'd53:alpha_rom=8'd84; 8'd54:alpha_rom=8'd84; 8'd55:alpha_rom=8'd85;
            8'd56:alpha_rom=8'd86; 8'd57:alpha_rom=8'd86; 8'd58:alpha_rom=8'd87; 8'd59:alpha_rom=8'd87; 8'd60:alpha_rom=8'd88; 8'd61:alpha_rom=8'd88; 8'd62:alpha_rom=8'd89; 8'd63:alpha_rom=8'd89;
            8'd64:alpha_rom=8'd90; 8'd65:alpha_rom=8'd90; 8'd66:alpha_rom=8'd91; 8'd67:alpha_rom=8'd91; 8'd68:alpha_rom=8'd92; 8'd69:alpha_rom=8'd92; 8'd70:alpha_rom=8'd93; 8'd71:alpha_rom=8'd93;
            8'd72:alpha_rom=8'd94; 8'd73:alpha_rom=8'd94; 8'd74:alpha_rom=8'd95; 8'd75:alpha_rom=8'd95; 8'd76:alpha_rom=8'd96; 8'd77:alpha_rom=8'd96; 8'd78:alpha_rom=8'd97; 8'd79:alpha_rom=8'd97;
            8'd80:alpha_rom=8'd98; 8'd81:alpha_rom=8'd98; 8'd82:alpha_rom=8'd99; 8'd83:alpha_rom=8'd99; 8'd84:alpha_rom=8'd100; 8'd85:alpha_rom=8'd100; 8'd86:alpha_rom=8'd100; 8'd87:alpha_rom=8'd101;
            8'd88:alpha_rom=8'd101; 8'd89:alpha_rom=8'd102; 8'd90:alpha_rom=8'd102; 8'd91:alpha_rom=8'd103; 8'd92:alpha_rom=8'd103; 8'd93:alpha_rom=8'd104; 8'd94:alpha_rom=8'd104; 8'd95:alpha_rom=8'd105;
            8'd96:alpha_rom=8'd105; 8'd97:alpha_rom=8'd106; 8'd98:alpha_rom=8'd106; 8'd99:alpha_rom=8'd107; 8'd100:alpha_rom=8'd107; 8'd101:alpha_rom=8'd108; 8'd102:alpha_rom=8'd108; 8'd103:alpha_rom=8'd109;
            8'd104:alpha_rom=8'd109; 8'd105:alpha_rom=8'd110; 8'd106:alpha_rom=8'd110; 8'd107:alpha_rom=8'd110; 8'd108:alpha_rom=8'd111; 8'd109:alpha_rom=8'd111; 8'd110:alpha_rom=8'd112; 8'd111:alpha_rom=8'd112;
            8'd112:alpha_rom=8'd113; 8'd113:alpha_rom=8'd113; 8'd114:alpha_rom=8'd114; 8'd115:alpha_rom=8'd114; 8'd116:alpha_rom=8'd115; 8'd117:alpha_rom=8'd115; 8'd118:alpha_rom=8'd116; 8'd119:alpha_rom=8'd116;
            8'd120:alpha_rom=8'd117; 8'd121:alpha_rom=8'd117; 8'd122:alpha_rom=8'd118; 8'd123:alpha_rom=8'd118; 8'd124:alpha_rom=8'd119; 8'd125:alpha_rom=8'd119; 8'd126:alpha_rom=8'd120; 8'd127:alpha_rom=8'd120;
            8'd128:alpha_rom=8'd121; 8'd129:alpha_rom=8'd121; 8'd130:alpha_rom=8'd122; 8'd131:alpha_rom=8'd122; 8'd132:alpha_rom=8'd123; 8'd133:alpha_rom=8'd123; 8'd134:alpha_rom=8'd124; 8'd135:alpha_rom=8'd124;
            8'd136:alpha_rom=8'd125; 8'd137:alpha_rom=8'd125; 8'd138:alpha_rom=8'd126; 8'd139:alpha_rom=8'd126; 8'd140:alpha_rom=8'd127; 8'd141:alpha_rom=8'd127; 8'd142:alpha_rom=8'd128; 8'd143:alpha_rom=8'd128;
            8'd144:alpha_rom=8'd129; 8'd145:alpha_rom=8'd129; 8'd146:alpha_rom=8'd130; 8'd147:alpha_rom=8'd130; 8'd148:alpha_rom=8'd131; 8'd149:alpha_rom=8'd131; 8'd150:alpha_rom=8'd132; 8'd151:alpha_rom=8'd133;
            8'd152:alpha_rom=8'd133; 8'd153:alpha_rom=8'd134; 8'd154:alpha_rom=8'd134; 8'd155:alpha_rom=8'd135; 8'd156:alpha_rom=8'd135; 8'd157:alpha_rom=8'd136; 8'd158:alpha_rom=8'd136; 8'd159:alpha_rom=8'd137;
            8'd160:alpha_rom=8'd138; 8'd161:alpha_rom=8'd138; 8'd162:alpha_rom=8'd139; 8'd163:alpha_rom=8'd139; 8'd164:alpha_rom=8'd140; 8'd165:alpha_rom=8'd140; 8'd166:alpha_rom=8'd141; 8'd167:alpha_rom=8'd142;
            8'd168:alpha_rom=8'd142; 8'd169:alpha_rom=8'd143; 8'd170:alpha_rom=8'd143; 8'd171:alpha_rom=8'd144; 8'd172:alpha_rom=8'd145; 8'd173:alpha_rom=8'd145; 8'd174:alpha_rom=8'd146; 8'd175:alpha_rom=8'd147;
            8'd176:alpha_rom=8'd147; 8'd177:alpha_rom=8'd148; 8'd178:alpha_rom=8'd149; 8'd179:alpha_rom=8'd149; 8'd180:alpha_rom=8'd150; 8'd181:alpha_rom=8'd151; 8'd182:alpha_rom=8'd151; 8'd183:alpha_rom=8'd152;
            8'd184:alpha_rom=8'd153; 8'd185:alpha_rom=8'd153; 8'd186:alpha_rom=8'd154; 8'd187:alpha_rom=8'd155; 8'd188:alpha_rom=8'd155; 8'd189:alpha_rom=8'd156; 8'd190:alpha_rom=8'd157; 8'd191:alpha_rom=8'd158;
            8'd192:alpha_rom=8'd158; 8'd193:alpha_rom=8'd159; 8'd194:alpha_rom=8'd160; 8'd195:alpha_rom=8'd161; 8'd196:alpha_rom=8'd161; 8'd197:alpha_rom=8'd162; 8'd198:alpha_rom=8'd163; 8'd199:alpha_rom=8'd164;
            8'd200:alpha_rom=8'd165; 8'd201:alpha_rom=8'd165; 8'd202:alpha_rom=8'd166; 8'd203:alpha_rom=8'd167; 8'd204:alpha_rom=8'd168; 8'd205:alpha_rom=8'd169; 8'd206:alpha_rom=8'd170; 8'd207:alpha_rom=8'd171;
            8'd208:alpha_rom=8'd172; 8'd209:alpha_rom=8'd173; 8'd210:alpha_rom=8'd173; 8'd211:alpha_rom=8'd174; 8'd212:alpha_rom=8'd175; 8'd213:alpha_rom=8'd176; 8'd214:alpha_rom=8'd177; 8'd215:alpha_rom=8'd179;
            8'd216:alpha_rom=8'd180; 8'd217:alpha_rom=8'd181; 8'd218:alpha_rom=8'd182; 8'd219:alpha_rom=8'd183; 8'd220:alpha_rom=8'd184; 8'd221:alpha_rom=8'd185; 8'd222:alpha_rom=8'd187; 8'd223:alpha_rom=8'd188;
            8'd224:alpha_rom=8'd189; 8'd225:alpha_rom=8'd190; 8'd226:alpha_rom=8'd192; 8'd227:alpha_rom=8'd193; 8'd228:alpha_rom=8'd195; 8'd229:alpha_rom=8'd196; 8'd230:alpha_rom=8'd198; 8'd231:alpha_rom=8'd199;
            8'd232:alpha_rom=8'd201; 8'd233:alpha_rom=8'd203; 8'd234:alpha_rom=8'd204; 8'd235:alpha_rom=8'd206; 8'd236:alpha_rom=8'd208; 8'd237:alpha_rom=8'd210; 8'd238:alpha_rom=8'd212; 8'd239:alpha_rom=8'd215;
            8'd240:alpha_rom=8'd217; 8'd241:alpha_rom=8'd219; 8'd242:alpha_rom=8'd222; 8'd243:alpha_rom=8'd225; 8'd244:alpha_rom=8'd228; 8'd245:alpha_rom=8'd231; 8'd246:alpha_rom=8'd235; 8'd247:alpha_rom=8'd239;
            8'd248:alpha_rom=8'd243; 8'd249:alpha_rom=8'd248; 8'd250:alpha_rom=8'd254; 8'd251:alpha_rom=8'd255; 8'd252:alpha_rom=8'd255; 8'd253:alpha_rom=8'd255; 8'd254:alpha_rom=8'd255; 8'd255:alpha_rom=8'd255;
            default: alpha_rom = 8'd128;
        endcase
        3'd3: case (addr)
            8'd0:alpha_rom=8'd17; 8'd1:alpha_rom=8'd23; 8'd2:alpha_rom=8'd27; 8'd3:alpha_rom=8'd30; 8'd4:alpha_rom=8'd32; 8'd5:alpha_rom=8'd34; 8'd6:alpha_rom=8'd36; 8'd7:alpha_rom=8'd38;
            8'd8:alpha_rom=8'd39; 8'd9:alpha_rom=8'd41; 8'd10:alpha_rom=8'd42; 8'd11:alpha_rom=8'd43; 8'd12:alpha_rom=8'd44; 8'd13:alpha_rom=8'd45; 8'd14:alpha_rom=8'd47; 8'd15:alpha_rom=8'd48;
            8'd16:alpha_rom=8'd49; 8'd17:alpha_rom=8'd50; 8'd18:alpha_rom=8'd51; 8'd19:alpha_rom=8'd52; 8'd20:alpha_rom=8'd52; 8'd21:alpha_rom=8'd53; 8'd22:alpha_rom=8'd54; 8'd23:alpha_rom=8'd55;
            8'd24:alpha_rom=8'd56; 8'd25:alpha_rom=8'd57; 8'd26:alpha_rom=8'd57; 8'd27:alpha_rom=8'd58; 8'd28:alpha_rom=8'd59; 8'd29:alpha_rom=8'd60; 8'd30:alpha_rom=8'd61; 8'd31:alpha_rom=8'd61;
            8'd32:alpha_rom=8'd62; 8'd33:alpha_rom=8'd63; 8'd34:alpha_rom=8'd63; 8'd35:alpha_rom=8'd64; 8'd36:alpha_rom=8'd65; 8'd37:alpha_rom=8'd65; 8'd38:alpha_rom=8'd66; 8'd39:alpha_rom=8'd67;
            8'd40:alpha_rom=8'd67; 8'd41:alpha_rom=8'd68; 8'd42:alpha_rom=8'd69; 8'd43:alpha_rom=8'd69; 8'd44:alpha_rom=8'd70; 8'd45:alpha_rom=8'd71; 8'd46:alpha_rom=8'd71; 8'd47:alpha_rom=8'd72;
            8'd48:alpha_rom=8'd73; 8'd49:alpha_rom=8'd73; 8'd50:alpha_rom=8'd74; 8'd51:alpha_rom=8'd74; 8'd52:alpha_rom=8'd75; 8'd53:alpha_rom=8'd76; 8'd54:alpha_rom=8'd76; 8'd55:alpha_rom=8'd77;
            8'd56:alpha_rom=8'd77; 8'd57:alpha_rom=8'd78; 8'd58:alpha_rom=8'd79; 8'd59:alpha_rom=8'd79; 8'd60:alpha_rom=8'd80; 8'd61:alpha_rom=8'd80; 8'd62:alpha_rom=8'd81; 8'd63:alpha_rom=8'd81;
            8'd64:alpha_rom=8'd82; 8'd65:alpha_rom=8'd83; 8'd66:alpha_rom=8'd83; 8'd67:alpha_rom=8'd84; 8'd68:alpha_rom=8'd84; 8'd69:alpha_rom=8'd85; 8'd70:alpha_rom=8'd85; 8'd71:alpha_rom=8'd86;
            8'd72:alpha_rom=8'd87; 8'd73:alpha_rom=8'd87; 8'd74:alpha_rom=8'd88; 8'd75:alpha_rom=8'd88; 8'd76:alpha_rom=8'd89; 8'd77:alpha_rom=8'd89; 8'd78:alpha_rom=8'd90; 8'd79:alpha_rom=8'd90;
            8'd80:alpha_rom=8'd91; 8'd81:alpha_rom=8'd92; 8'd82:alpha_rom=8'd92; 8'd83:alpha_rom=8'd93; 8'd84:alpha_rom=8'd93; 8'd85:alpha_rom=8'd94; 8'd86:alpha_rom=8'd94; 8'd87:alpha_rom=8'd95;
            8'd88:alpha_rom=8'd95; 8'd89:alpha_rom=8'd96; 8'd90:alpha_rom=8'd97; 8'd91:alpha_rom=8'd97; 8'd92:alpha_rom=8'd98; 8'd93:alpha_rom=8'd98; 8'd94:alpha_rom=8'd99; 8'd95:alpha_rom=8'd99;
            8'd96:alpha_rom=8'd100; 8'd97:alpha_rom=8'd100; 8'd98:alpha_rom=8'd101; 8'd99:alpha_rom=8'd101; 8'd100:alpha_rom=8'd102; 8'd101:alpha_rom=8'd103; 8'd102:alpha_rom=8'd103; 8'd103:alpha_rom=8'd104;
            8'd104:alpha_rom=8'd104; 8'd105:alpha_rom=8'd105; 8'd106:alpha_rom=8'd105; 8'd107:alpha_rom=8'd106; 8'd108:alpha_rom=8'd106; 8'd109:alpha_rom=8'd107; 8'd110:alpha_rom=8'd108; 8'd111:alpha_rom=8'd108;
            8'd112:alpha_rom=8'd109; 8'd113:alpha_rom=8'd109; 8'd114:alpha_rom=8'd110; 8'd115:alpha_rom=8'd110; 8'd116:alpha_rom=8'd111; 8'd117:alpha_rom=8'd111; 8'd118:alpha_rom=8'd112; 8'd119:alpha_rom=8'd113;
            8'd120:alpha_rom=8'd113; 8'd121:alpha_rom=8'd114; 8'd122:alpha_rom=8'd114; 8'd123:alpha_rom=8'd115; 8'd124:alpha_rom=8'd115; 8'd125:alpha_rom=8'd116; 8'd126:alpha_rom=8'd117; 8'd127:alpha_rom=8'd117;
            8'd128:alpha_rom=8'd118; 8'd129:alpha_rom=8'd118; 8'd130:alpha_rom=8'd119; 8'd131:alpha_rom=8'd120; 8'd132:alpha_rom=8'd120; 8'd133:alpha_rom=8'd121; 8'd134:alpha_rom=8'd121; 8'd135:alpha_rom=8'd122;
            8'd136:alpha_rom=8'd123; 8'd137:alpha_rom=8'd123; 8'd138:alpha_rom=8'd124; 8'd139:alpha_rom=8'd124; 8'd140:alpha_rom=8'd125; 8'd141:alpha_rom=8'd126; 8'd142:alpha_rom=8'd126; 8'd143:alpha_rom=8'd127;
            8'd144:alpha_rom=8'd127; 8'd145:alpha_rom=8'd128; 8'd146:alpha_rom=8'd129; 8'd147:alpha_rom=8'd129; 8'd148:alpha_rom=8'd130; 8'd149:alpha_rom=8'd131; 8'd150:alpha_rom=8'd131; 8'd151:alpha_rom=8'd132;
            8'd152:alpha_rom=8'd133; 8'd153:alpha_rom=8'd133; 8'd154:alpha_rom=8'd134; 8'd155:alpha_rom=8'd134; 8'd156:alpha_rom=8'd135; 8'd157:alpha_rom=8'd136; 8'd158:alpha_rom=8'd136; 8'd159:alpha_rom=8'd137;
            8'd160:alpha_rom=8'd138; 8'd161:alpha_rom=8'd139; 8'd162:alpha_rom=8'd139; 8'd163:alpha_rom=8'd140; 8'd164:alpha_rom=8'd141; 8'd165:alpha_rom=8'd141; 8'd166:alpha_rom=8'd142; 8'd167:alpha_rom=8'd143;
            8'd168:alpha_rom=8'd143; 8'd169:alpha_rom=8'd144; 8'd170:alpha_rom=8'd145; 8'd171:alpha_rom=8'd146; 8'd172:alpha_rom=8'd146; 8'd173:alpha_rom=8'd147; 8'd174:alpha_rom=8'd148; 8'd175:alpha_rom=8'd149;
            8'd176:alpha_rom=8'd149; 8'd177:alpha_rom=8'd150; 8'd178:alpha_rom=8'd151; 8'd179:alpha_rom=8'd152; 8'd180:alpha_rom=8'd153; 8'd181:alpha_rom=8'd153; 8'd182:alpha_rom=8'd154; 8'd183:alpha_rom=8'd155;
            8'd184:alpha_rom=8'd156; 8'd185:alpha_rom=8'd157; 8'd186:alpha_rom=8'd158; 8'd187:alpha_rom=8'd158; 8'd188:alpha_rom=8'd159; 8'd189:alpha_rom=8'd160; 8'd190:alpha_rom=8'd161; 8'd191:alpha_rom=8'd162;
            8'd192:alpha_rom=8'd163; 8'd193:alpha_rom=8'd164; 8'd194:alpha_rom=8'd165; 8'd195:alpha_rom=8'd166; 8'd196:alpha_rom=8'd167; 8'd197:alpha_rom=8'd168; 8'd198:alpha_rom=8'd169; 8'd199:alpha_rom=8'd169;
            8'd200:alpha_rom=8'd171; 8'd201:alpha_rom=8'd172; 8'd202:alpha_rom=8'd173; 8'd203:alpha_rom=8'd174; 8'd204:alpha_rom=8'd175; 8'd205:alpha_rom=8'd176; 8'd206:alpha_rom=8'd177; 8'd207:alpha_rom=8'd178;
            8'd208:alpha_rom=8'd179; 8'd209:alpha_rom=8'd180; 8'd210:alpha_rom=8'd181; 8'd211:alpha_rom=8'd183; 8'd212:alpha_rom=8'd184; 8'd213:alpha_rom=8'd185; 8'd214:alpha_rom=8'd186; 8'd215:alpha_rom=8'd188;
            8'd216:alpha_rom=8'd189; 8'd217:alpha_rom=8'd190; 8'd218:alpha_rom=8'd192; 8'd219:alpha_rom=8'd193; 8'd220:alpha_rom=8'd195; 8'd221:alpha_rom=8'd196; 8'd222:alpha_rom=8'd198; 8'd223:alpha_rom=8'd199;
            8'd224:alpha_rom=8'd201; 8'd225:alpha_rom=8'd202; 8'd226:alpha_rom=8'd204; 8'd227:alpha_rom=8'd206; 8'd228:alpha_rom=8'd208; 8'd229:alpha_rom=8'd209; 8'd230:alpha_rom=8'd211; 8'd231:alpha_rom=8'd213;
            8'd232:alpha_rom=8'd215; 8'd233:alpha_rom=8'd218; 8'd234:alpha_rom=8'd220; 8'd235:alpha_rom=8'd222; 8'd236:alpha_rom=8'd225; 8'd237:alpha_rom=8'd227; 8'd238:alpha_rom=8'd230; 8'd239:alpha_rom=8'd233;
            8'd240:alpha_rom=8'd236; 8'd241:alpha_rom=8'd239; 8'd242:alpha_rom=8'd242; 8'd243:alpha_rom=8'd246; 8'd244:alpha_rom=8'd249; 8'd245:alpha_rom=8'd254; 8'd246:alpha_rom=8'd255; 8'd247:alpha_rom=8'd255;
            8'd248:alpha_rom=8'd255; 8'd249:alpha_rom=8'd255; 8'd250:alpha_rom=8'd255; 8'd251:alpha_rom=8'd255; 8'd252:alpha_rom=8'd255; 8'd253:alpha_rom=8'd255; 8'd254:alpha_rom=8'd255; 8'd255:alpha_rom=8'd255;
            default: alpha_rom = 8'd128;
        endcase
        3'd4: case (addr)
            8'd0:alpha_rom=8'd17; 8'd1:alpha_rom=8'd23; 8'd2:alpha_rom=8'd26; 8'd3:alpha_rom=8'd29; 8'd4:alpha_rom=8'd32; 8'd5:alpha_rom=8'd34; 8'd6:alpha_rom=8'd35; 8'd7:alpha_rom=8'd37;
            8'd8:alpha_rom=8'd39; 8'd9:alpha_rom=8'd40; 8'd10:alpha_rom=8'd41; 8'd11:alpha_rom=8'd43; 8'd12:alpha_rom=8'd44; 8'd13:alpha_rom=8'd45; 8'd14:alpha_rom=8'd46; 8'd15:alpha_rom=8'd47;
            8'd16:alpha_rom=8'd48; 8'd17:alpha_rom=8'd49; 8'd18:alpha_rom=8'd50; 8'd19:alpha_rom=8'd51; 8'd20:alpha_rom=8'd52; 8'd21:alpha_rom=8'd53; 8'd22:alpha_rom=8'd54; 8'd23:alpha_rom=8'd54;
            8'd24:alpha_rom=8'd55; 8'd25:alpha_rom=8'd56; 8'd26:alpha_rom=8'd57; 8'd27:alpha_rom=8'd58; 8'd28:alpha_rom=8'd58; 8'd29:alpha_rom=8'd59; 8'd30:alpha_rom=8'd60; 8'd31:alpha_rom=8'd61;
            8'd32:alpha_rom=8'd61; 8'd33:alpha_rom=8'd62; 8'd34:alpha_rom=8'd63; 8'd35:alpha_rom=8'd64; 8'd36:alpha_rom=8'd64; 8'd37:alpha_rom=8'd65; 8'd38:alpha_rom=8'd66; 8'd39:alpha_rom=8'd66;
            8'd40:alpha_rom=8'd67; 8'd41:alpha_rom=8'd68; 8'd42:alpha_rom=8'd68; 8'd43:alpha_rom=8'd69; 8'd44:alpha_rom=8'd70; 8'd45:alpha_rom=8'd70; 8'd46:alpha_rom=8'd71; 8'd47:alpha_rom=8'd71;
            8'd48:alpha_rom=8'd72; 8'd49:alpha_rom=8'd73; 8'd50:alpha_rom=8'd73; 8'd51:alpha_rom=8'd74; 8'd52:alpha_rom=8'd75; 8'd53:alpha_rom=8'd75; 8'd54:alpha_rom=8'd76; 8'd55:alpha_rom=8'd76;
            8'd56:alpha_rom=8'd77; 8'd57:alpha_rom=8'd78; 8'd58:alpha_rom=8'd78; 8'd59:alpha_rom=8'd79; 8'd60:alpha_rom=8'd79; 8'd61:alpha_rom=8'd80; 8'd62:alpha_rom=8'd80; 8'd63:alpha_rom=8'd81;
            8'd64:alpha_rom=8'd82; 8'd65:alpha_rom=8'd82; 8'd66:alpha_rom=8'd83; 8'd67:alpha_rom=8'd83; 8'd68:alpha_rom=8'd84; 8'd69:alpha_rom=8'd84; 8'd70:alpha_rom=8'd85; 8'd71:alpha_rom=8'd86;
            8'd72:alpha_rom=8'd86; 8'd73:alpha_rom=8'd87; 8'd74:alpha_rom=8'd87; 8'd75:alpha_rom=8'd88; 8'd76:alpha_rom=8'd88; 8'd77:alpha_rom=8'd89; 8'd78:alpha_rom=8'd90; 8'd79:alpha_rom=8'd90;
            8'd80:alpha_rom=8'd91; 8'd81:alpha_rom=8'd91; 8'd82:alpha_rom=8'd92; 8'd83:alpha_rom=8'd92; 8'd84:alpha_rom=8'd93; 8'd85:alpha_rom=8'd93; 8'd86:alpha_rom=8'd94; 8'd87:alpha_rom=8'd95;
            8'd88:alpha_rom=8'd95; 8'd89:alpha_rom=8'd96; 8'd90:alpha_rom=8'd96; 8'd91:alpha_rom=8'd97; 8'd92:alpha_rom=8'd97; 8'd93:alpha_rom=8'd98; 8'd94:alpha_rom=8'd98; 8'd95:alpha_rom=8'd99;
            8'd96:alpha_rom=8'd99; 8'd97:alpha_rom=8'd100; 8'd98:alpha_rom=8'd101; 8'd99:alpha_rom=8'd101; 8'd100:alpha_rom=8'd102; 8'd101:alpha_rom=8'd102; 8'd102:alpha_rom=8'd103; 8'd103:alpha_rom=8'd103;
            8'd104:alpha_rom=8'd104; 8'd105:alpha_rom=8'd104; 8'd106:alpha_rom=8'd105; 8'd107:alpha_rom=8'd106; 8'd108:alpha_rom=8'd106; 8'd109:alpha_rom=8'd107; 8'd110:alpha_rom=8'd107; 8'd111:alpha_rom=8'd108;
            8'd112:alpha_rom=8'd108; 8'd113:alpha_rom=8'd109; 8'd114:alpha_rom=8'd110; 8'd115:alpha_rom=8'd110; 8'd116:alpha_rom=8'd111; 8'd117:alpha_rom=8'd111; 8'd118:alpha_rom=8'd112; 8'd119:alpha_rom=8'd112;
            8'd120:alpha_rom=8'd113; 8'd121:alpha_rom=8'd114; 8'd122:alpha_rom=8'd114; 8'd123:alpha_rom=8'd115; 8'd124:alpha_rom=8'd115; 8'd125:alpha_rom=8'd116; 8'd126:alpha_rom=8'd116; 8'd127:alpha_rom=8'd117;
            8'd128:alpha_rom=8'd118; 8'd129:alpha_rom=8'd118; 8'd130:alpha_rom=8'd119; 8'd131:alpha_rom=8'd119; 8'd132:alpha_rom=8'd120; 8'd133:alpha_rom=8'd121; 8'd134:alpha_rom=8'd121; 8'd135:alpha_rom=8'd122;
            8'd136:alpha_rom=8'd122; 8'd137:alpha_rom=8'd123; 8'd138:alpha_rom=8'd124; 8'd139:alpha_rom=8'd124; 8'd140:alpha_rom=8'd125; 8'd141:alpha_rom=8'd125; 8'd142:alpha_rom=8'd126; 8'd143:alpha_rom=8'd127;
            8'd144:alpha_rom=8'd127; 8'd145:alpha_rom=8'd128; 8'd146:alpha_rom=8'd129; 8'd147:alpha_rom=8'd129; 8'd148:alpha_rom=8'd130; 8'd149:alpha_rom=8'd131; 8'd150:alpha_rom=8'd131; 8'd151:alpha_rom=8'd132;
            8'd152:alpha_rom=8'd132; 8'd153:alpha_rom=8'd133; 8'd154:alpha_rom=8'd134; 8'd155:alpha_rom=8'd134; 8'd156:alpha_rom=8'd135; 8'd157:alpha_rom=8'd136; 8'd158:alpha_rom=8'd136; 8'd159:alpha_rom=8'd137;
            8'd160:alpha_rom=8'd138; 8'd161:alpha_rom=8'd139; 8'd162:alpha_rom=8'd139; 8'd163:alpha_rom=8'd140; 8'd164:alpha_rom=8'd141; 8'd165:alpha_rom=8'd141; 8'd166:alpha_rom=8'd142; 8'd167:alpha_rom=8'd143;
            8'd168:alpha_rom=8'd144; 8'd169:alpha_rom=8'd144; 8'd170:alpha_rom=8'd145; 8'd171:alpha_rom=8'd146; 8'd172:alpha_rom=8'd146; 8'd173:alpha_rom=8'd147; 8'd174:alpha_rom=8'd148; 8'd175:alpha_rom=8'd149;
            8'd176:alpha_rom=8'd150; 8'd177:alpha_rom=8'd150; 8'd178:alpha_rom=8'd151; 8'd179:alpha_rom=8'd152; 8'd180:alpha_rom=8'd153; 8'd181:alpha_rom=8'd154; 8'd182:alpha_rom=8'd154; 8'd183:alpha_rom=8'd155;
            8'd184:alpha_rom=8'd156; 8'd185:alpha_rom=8'd157; 8'd186:alpha_rom=8'd158; 8'd187:alpha_rom=8'd159; 8'd188:alpha_rom=8'd159; 8'd189:alpha_rom=8'd160; 8'd190:alpha_rom=8'd161; 8'd191:alpha_rom=8'd162;
            8'd192:alpha_rom=8'd163; 8'd193:alpha_rom=8'd164; 8'd194:alpha_rom=8'd165; 8'd195:alpha_rom=8'd166; 8'd196:alpha_rom=8'd167; 8'd197:alpha_rom=8'd168; 8'd198:alpha_rom=8'd169; 8'd199:alpha_rom=8'd170;
            8'd200:alpha_rom=8'd171; 8'd201:alpha_rom=8'd172; 8'd202:alpha_rom=8'd173; 8'd203:alpha_rom=8'd174; 8'd204:alpha_rom=8'd175; 8'd205:alpha_rom=8'd176; 8'd206:alpha_rom=8'd177; 8'd207:alpha_rom=8'd178;
            8'd208:alpha_rom=8'd180; 8'd209:alpha_rom=8'd181; 8'd210:alpha_rom=8'd182; 8'd211:alpha_rom=8'd183; 8'd212:alpha_rom=8'd184; 8'd213:alpha_rom=8'd186; 8'd214:alpha_rom=8'd187; 8'd215:alpha_rom=8'd188;
            8'd216:alpha_rom=8'd190; 8'd217:alpha_rom=8'd191; 8'd218:alpha_rom=8'd192; 8'd219:alpha_rom=8'd194; 8'd220:alpha_rom=8'd195; 8'd221:alpha_rom=8'd197; 8'd222:alpha_rom=8'd198; 8'd223:alpha_rom=8'd200;
            8'd224:alpha_rom=8'd201; 8'd225:alpha_rom=8'd203; 8'd226:alpha_rom=8'd205; 8'd227:alpha_rom=8'd207; 8'd228:alpha_rom=8'd208; 8'd229:alpha_rom=8'd210; 8'd230:alpha_rom=8'd212; 8'd231:alpha_rom=8'd214;
            8'd232:alpha_rom=8'd216; 8'd233:alpha_rom=8'd218; 8'd234:alpha_rom=8'd221; 8'd235:alpha_rom=8'd223; 8'd236:alpha_rom=8'd226; 8'd237:alpha_rom=8'd228; 8'd238:alpha_rom=8'd231; 8'd239:alpha_rom=8'd234;
            8'd240:alpha_rom=8'd237; 8'd241:alpha_rom=8'd240; 8'd242:alpha_rom=8'd243; 8'd243:alpha_rom=8'd247; 8'd244:alpha_rom=8'd251; 8'd245:alpha_rom=8'd255; 8'd246:alpha_rom=8'd255; 8'd247:alpha_rom=8'd255;
            8'd248:alpha_rom=8'd255; 8'd249:alpha_rom=8'd255; 8'd250:alpha_rom=8'd255; 8'd251:alpha_rom=8'd255; 8'd252:alpha_rom=8'd255; 8'd253:alpha_rom=8'd255; 8'd254:alpha_rom=8'd255; 8'd255:alpha_rom=8'd255;
            default: alpha_rom = 8'd128;
        endcase
        3'd5: case (addr)
            8'd0:alpha_rom=8'd23; 8'd1:alpha_rom=8'd30; 8'd2:alpha_rom=8'd34; 8'd3:alpha_rom=8'd37; 8'd4:alpha_rom=8'd39; 8'd5:alpha_rom=8'd41; 8'd6:alpha_rom=8'd43; 8'd7:alpha_rom=8'd44;
            8'd8:alpha_rom=8'd46; 8'd9:alpha_rom=8'd47; 8'd10:alpha_rom=8'd49; 8'd11:alpha_rom=8'd50; 8'd12:alpha_rom=8'd51; 8'd13:alpha_rom=8'd52; 8'd14:alpha_rom=8'd53; 8'd15:alpha_rom=8'd54;
            8'd16:alpha_rom=8'd55; 8'd17:alpha_rom=8'd56; 8'd18:alpha_rom=8'd57; 8'd19:alpha_rom=8'd58; 8'd20:alpha_rom=8'd59; 8'd21:alpha_rom=8'd60; 8'd22:alpha_rom=8'd61; 8'd23:alpha_rom=8'd62;
            8'd24:alpha_rom=8'd62; 8'd25:alpha_rom=8'd63; 8'd26:alpha_rom=8'd64; 8'd27:alpha_rom=8'd65; 8'd28:alpha_rom=8'd65; 8'd29:alpha_rom=8'd66; 8'd30:alpha_rom=8'd67; 8'd31:alpha_rom=8'd68;
            8'd32:alpha_rom=8'd68; 8'd33:alpha_rom=8'd69; 8'd34:alpha_rom=8'd70; 8'd35:alpha_rom=8'd70; 8'd36:alpha_rom=8'd71; 8'd37:alpha_rom=8'd72; 8'd38:alpha_rom=8'd72; 8'd39:alpha_rom=8'd73;
            8'd40:alpha_rom=8'd73; 8'd41:alpha_rom=8'd74; 8'd42:alpha_rom=8'd75; 8'd43:alpha_rom=8'd75; 8'd44:alpha_rom=8'd76; 8'd45:alpha_rom=8'd77; 8'd46:alpha_rom=8'd77; 8'd47:alpha_rom=8'd78;
            8'd48:alpha_rom=8'd78; 8'd49:alpha_rom=8'd79; 8'd50:alpha_rom=8'd79; 8'd51:alpha_rom=8'd80; 8'd52:alpha_rom=8'd81; 8'd53:alpha_rom=8'd81; 8'd54:alpha_rom=8'd82; 8'd55:alpha_rom=8'd82;
            8'd56:alpha_rom=8'd83; 8'd57:alpha_rom=8'd83; 8'd58:alpha_rom=8'd84; 8'd59:alpha_rom=8'd84; 8'd60:alpha_rom=8'd85; 8'd61:alpha_rom=8'd86; 8'd62:alpha_rom=8'd86; 8'd63:alpha_rom=8'd87;
            8'd64:alpha_rom=8'd87; 8'd65:alpha_rom=8'd88; 8'd66:alpha_rom=8'd88; 8'd67:alpha_rom=8'd89; 8'd68:alpha_rom=8'd89; 8'd69:alpha_rom=8'd90; 8'd70:alpha_rom=8'd90; 8'd71:alpha_rom=8'd91;
            8'd72:alpha_rom=8'd91; 8'd73:alpha_rom=8'd92; 8'd74:alpha_rom=8'd92; 8'd75:alpha_rom=8'd93; 8'd76:alpha_rom=8'd93; 8'd77:alpha_rom=8'd94; 8'd78:alpha_rom=8'd94; 8'd79:alpha_rom=8'd95;
            8'd80:alpha_rom=8'd95; 8'd81:alpha_rom=8'd96; 8'd82:alpha_rom=8'd96; 8'd83:alpha_rom=8'd97; 8'd84:alpha_rom=8'd97; 8'd85:alpha_rom=8'd98; 8'd86:alpha_rom=8'd98; 8'd87:alpha_rom=8'd99;
            8'd88:alpha_rom=8'd99; 8'd89:alpha_rom=8'd100; 8'd90:alpha_rom=8'd100; 8'd91:alpha_rom=8'd101; 8'd92:alpha_rom=8'd101; 8'd93:alpha_rom=8'd102; 8'd94:alpha_rom=8'd102; 8'd95:alpha_rom=8'd103;
            8'd96:alpha_rom=8'd103; 8'd97:alpha_rom=8'd104; 8'd98:alpha_rom=8'd104; 8'd99:alpha_rom=8'd105; 8'd100:alpha_rom=8'd105; 8'd101:alpha_rom=8'd106; 8'd102:alpha_rom=8'd106; 8'd103:alpha_rom=8'd107;
            8'd104:alpha_rom=8'd107; 8'd105:alpha_rom=8'd108; 8'd106:alpha_rom=8'd108; 8'd107:alpha_rom=8'd109; 8'd108:alpha_rom=8'd109; 8'd109:alpha_rom=8'd110; 8'd110:alpha_rom=8'd110; 8'd111:alpha_rom=8'd111;
            8'd112:alpha_rom=8'd112; 8'd113:alpha_rom=8'd112; 8'd114:alpha_rom=8'd113; 8'd115:alpha_rom=8'd113; 8'd116:alpha_rom=8'd114; 8'd117:alpha_rom=8'd114; 8'd118:alpha_rom=8'd115; 8'd119:alpha_rom=8'd115;
            8'd120:alpha_rom=8'd116; 8'd121:alpha_rom=8'd116; 8'd122:alpha_rom=8'd117; 8'd123:alpha_rom=8'd117; 8'd124:alpha_rom=8'd118; 8'd125:alpha_rom=8'd118; 8'd126:alpha_rom=8'd119; 8'd127:alpha_rom=8'd119;
            8'd128:alpha_rom=8'd120; 8'd129:alpha_rom=8'd120; 8'd130:alpha_rom=8'd121; 8'd131:alpha_rom=8'd121; 8'd132:alpha_rom=8'd122; 8'd133:alpha_rom=8'd122; 8'd134:alpha_rom=8'd123; 8'd135:alpha_rom=8'd123;
            8'd136:alpha_rom=8'd124; 8'd137:alpha_rom=8'd125; 8'd138:alpha_rom=8'd125; 8'd139:alpha_rom=8'd126; 8'd140:alpha_rom=8'd126; 8'd141:alpha_rom=8'd127; 8'd142:alpha_rom=8'd127; 8'd143:alpha_rom=8'd128;
            8'd144:alpha_rom=8'd128; 8'd145:alpha_rom=8'd129; 8'd146:alpha_rom=8'd130; 8'd147:alpha_rom=8'd130; 8'd148:alpha_rom=8'd131; 8'd149:alpha_rom=8'd131; 8'd150:alpha_rom=8'd132; 8'd151:alpha_rom=8'd132;
            8'd152:alpha_rom=8'd133; 8'd153:alpha_rom=8'd134; 8'd154:alpha_rom=8'd134; 8'd155:alpha_rom=8'd135; 8'd156:alpha_rom=8'd135; 8'd157:alpha_rom=8'd136; 8'd158:alpha_rom=8'd137; 8'd159:alpha_rom=8'd137;
            8'd160:alpha_rom=8'd138; 8'd161:alpha_rom=8'd138; 8'd162:alpha_rom=8'd139; 8'd163:alpha_rom=8'd140; 8'd164:alpha_rom=8'd140; 8'd165:alpha_rom=8'd141; 8'd166:alpha_rom=8'd141; 8'd167:alpha_rom=8'd142;
            8'd168:alpha_rom=8'd143; 8'd169:alpha_rom=8'd143; 8'd170:alpha_rom=8'd144; 8'd171:alpha_rom=8'd145; 8'd172:alpha_rom=8'd145; 8'd173:alpha_rom=8'd146; 8'd174:alpha_rom=8'd147; 8'd175:alpha_rom=8'd147;
            8'd176:alpha_rom=8'd148; 8'd177:alpha_rom=8'd149; 8'd178:alpha_rom=8'd149; 8'd179:alpha_rom=8'd150; 8'd180:alpha_rom=8'd151; 8'd181:alpha_rom=8'd152; 8'd182:alpha_rom=8'd152; 8'd183:alpha_rom=8'd153;
            8'd184:alpha_rom=8'd154; 8'd185:alpha_rom=8'd154; 8'd186:alpha_rom=8'd155; 8'd187:alpha_rom=8'd156; 8'd188:alpha_rom=8'd157; 8'd189:alpha_rom=8'd157; 8'd190:alpha_rom=8'd158; 8'd191:alpha_rom=8'd159;
            8'd192:alpha_rom=8'd160; 8'd193:alpha_rom=8'd161; 8'd194:alpha_rom=8'd161; 8'd195:alpha_rom=8'd162; 8'd196:alpha_rom=8'd163; 8'd197:alpha_rom=8'd164; 8'd198:alpha_rom=8'd165; 8'd199:alpha_rom=8'd166;
            8'd200:alpha_rom=8'd167; 8'd201:alpha_rom=8'd168; 8'd202:alpha_rom=8'd168; 8'd203:alpha_rom=8'd169; 8'd204:alpha_rom=8'd170; 8'd205:alpha_rom=8'd171; 8'd206:alpha_rom=8'd172; 8'd207:alpha_rom=8'd173;
            8'd208:alpha_rom=8'd174; 8'd209:alpha_rom=8'd175; 8'd210:alpha_rom=8'd176; 8'd211:alpha_rom=8'd177; 8'd212:alpha_rom=8'd178; 8'd213:alpha_rom=8'd179; 8'd214:alpha_rom=8'd181; 8'd215:alpha_rom=8'd182;
            8'd216:alpha_rom=8'd183; 8'd217:alpha_rom=8'd184; 8'd218:alpha_rom=8'd185; 8'd219:alpha_rom=8'd186; 8'd220:alpha_rom=8'd188; 8'd221:alpha_rom=8'd189; 8'd222:alpha_rom=8'd190; 8'd223:alpha_rom=8'd192;
            8'd224:alpha_rom=8'd193; 8'd225:alpha_rom=8'd194; 8'd226:alpha_rom=8'd196; 8'd227:alpha_rom=8'd197; 8'd228:alpha_rom=8'd199; 8'd229:alpha_rom=8'd201; 8'd230:alpha_rom=8'd202; 8'd231:alpha_rom=8'd204;
            8'd232:alpha_rom=8'd206; 8'd233:alpha_rom=8'd208; 8'd234:alpha_rom=8'd210; 8'd235:alpha_rom=8'd212; 8'd236:alpha_rom=8'd214; 8'd237:alpha_rom=8'd216; 8'd238:alpha_rom=8'd218; 8'd239:alpha_rom=8'd221;
            8'd240:alpha_rom=8'd223; 8'd241:alpha_rom=8'd226; 8'd242:alpha_rom=8'd229; 8'd243:alpha_rom=8'd232; 8'd244:alpha_rom=8'd235; 8'd245:alpha_rom=8'd239; 8'd246:alpha_rom=8'd243; 8'd247:alpha_rom=8'd247;
            8'd248:alpha_rom=8'd252; 8'd249:alpha_rom=8'd255; 8'd250:alpha_rom=8'd255; 8'd251:alpha_rom=8'd255; 8'd252:alpha_rom=8'd255; 8'd253:alpha_rom=8'd255; 8'd254:alpha_rom=8'd255; 8'd255:alpha_rom=8'd255;
            default: alpha_rom = 8'd128;
        endcase
        default: alpha_rom = 8'd128;
    endcase
end
endfunction

// Small-scale fading ROM
function [7:0] beta_rom;
    input [2:0] level;
    input [7:0] addr;
begin
    case (level)
        3'd1: case (addr)
            8'd0:beta_rom=8'd41; 8'd1:beta_rom=8'd49; 8'd2:beta_rom=8'd53; 8'd3:beta_rom=8'd55; 8'd4:beta_rom=8'd58; 8'd5:beta_rom=8'd60; 8'd6:beta_rom=8'd61; 8'd7:beta_rom=8'd63;
            8'd8:beta_rom=8'd64; 8'd9:beta_rom=8'd66; 8'd10:beta_rom=8'd67; 8'd11:beta_rom=8'd68; 8'd12:beta_rom=8'd69; 8'd13:beta_rom=8'd70; 8'd14:beta_rom=8'd71; 8'd15:beta_rom=8'd72;
            8'd16:beta_rom=8'd73; 8'd17:beta_rom=8'd74; 8'd18:beta_rom=8'd74; 8'd19:beta_rom=8'd75; 8'd20:beta_rom=8'd76; 8'd21:beta_rom=8'd77; 8'd22:beta_rom=8'd77; 8'd23:beta_rom=8'd78;
            8'd24:beta_rom=8'd79; 8'd25:beta_rom=8'd79; 8'd26:beta_rom=8'd80; 8'd27:beta_rom=8'd81; 8'd28:beta_rom=8'd81; 8'd29:beta_rom=8'd82; 8'd30:beta_rom=8'd82; 8'd31:beta_rom=8'd83;
            8'd32:beta_rom=8'd84; 8'd33:beta_rom=8'd84; 8'd34:beta_rom=8'd85; 8'd35:beta_rom=8'd85; 8'd36:beta_rom=8'd86; 8'd37:beta_rom=8'd86; 8'd38:beta_rom=8'd87; 8'd39:beta_rom=8'd87;
            8'd40:beta_rom=8'd88; 8'd41:beta_rom=8'd88; 8'd42:beta_rom=8'd89; 8'd43:beta_rom=8'd89; 8'd44:beta_rom=8'd90; 8'd45:beta_rom=8'd90; 8'd46:beta_rom=8'd91; 8'd47:beta_rom=8'd91;
            8'd48:beta_rom=8'd92; 8'd49:beta_rom=8'd92; 8'd50:beta_rom=8'd93; 8'd51:beta_rom=8'd93; 8'd52:beta_rom=8'd94; 8'd53:beta_rom=8'd94; 8'd54:beta_rom=8'd94; 8'd55:beta_rom=8'd95;
            8'd56:beta_rom=8'd95; 8'd57:beta_rom=8'd96; 8'd58:beta_rom=8'd96; 8'd59:beta_rom=8'd97; 8'd60:beta_rom=8'd97; 8'd61:beta_rom=8'd98; 8'd62:beta_rom=8'd98; 8'd63:beta_rom=8'd98;
            8'd64:beta_rom=8'd99; 8'd65:beta_rom=8'd99; 8'd66:beta_rom=8'd100; 8'd67:beta_rom=8'd100; 8'd68:beta_rom=8'd100; 8'd69:beta_rom=8'd101; 8'd70:beta_rom=8'd101; 8'd71:beta_rom=8'd102;
            8'd72:beta_rom=8'd102; 8'd73:beta_rom=8'd102; 8'd74:beta_rom=8'd103; 8'd75:beta_rom=8'd103; 8'd76:beta_rom=8'd104; 8'd77:beta_rom=8'd104; 8'd78:beta_rom=8'd104; 8'd79:beta_rom=8'd105;
            8'd80:beta_rom=8'd105; 8'd81:beta_rom=8'd106; 8'd82:beta_rom=8'd106; 8'd83:beta_rom=8'd106; 8'd84:beta_rom=8'd107; 8'd85:beta_rom=8'd107; 8'd86:beta_rom=8'd108; 8'd87:beta_rom=8'd108;
            8'd88:beta_rom=8'd108; 8'd89:beta_rom=8'd109; 8'd90:beta_rom=8'd109; 8'd91:beta_rom=8'd109; 8'd92:beta_rom=8'd110; 8'd93:beta_rom=8'd110; 8'd94:beta_rom=8'd111; 8'd95:beta_rom=8'd111;
            8'd96:beta_rom=8'd111; 8'd97:beta_rom=8'd112; 8'd98:beta_rom=8'd112; 8'd99:beta_rom=8'd112; 8'd100:beta_rom=8'd113; 8'd101:beta_rom=8'd113; 8'd102:beta_rom=8'd114; 8'd103:beta_rom=8'd114;
            8'd104:beta_rom=8'd114; 8'd105:beta_rom=8'd115; 8'd106:beta_rom=8'd115; 8'd107:beta_rom=8'd116; 8'd108:beta_rom=8'd116; 8'd109:beta_rom=8'd116; 8'd110:beta_rom=8'd117; 8'd111:beta_rom=8'd117;
            8'd112:beta_rom=8'd117; 8'd113:beta_rom=8'd118; 8'd114:beta_rom=8'd118; 8'd115:beta_rom=8'd119; 8'd116:beta_rom=8'd119; 8'd117:beta_rom=8'd119; 8'd118:beta_rom=8'd120; 8'd119:beta_rom=8'd120;
            8'd120:beta_rom=8'd120; 8'd121:beta_rom=8'd121; 8'd122:beta_rom=8'd121; 8'd123:beta_rom=8'd122; 8'd124:beta_rom=8'd122; 8'd125:beta_rom=8'd122; 8'd126:beta_rom=8'd123; 8'd127:beta_rom=8'd123;
            8'd128:beta_rom=8'd124; 8'd129:beta_rom=8'd124; 8'd130:beta_rom=8'd124; 8'd131:beta_rom=8'd125; 8'd132:beta_rom=8'd125; 8'd133:beta_rom=8'd125; 8'd134:beta_rom=8'd126; 8'd135:beta_rom=8'd126;
            8'd136:beta_rom=8'd127; 8'd137:beta_rom=8'd127; 8'd138:beta_rom=8'd127; 8'd139:beta_rom=8'd128; 8'd140:beta_rom=8'd128; 8'd141:beta_rom=8'd129; 8'd142:beta_rom=8'd129; 8'd143:beta_rom=8'd129;
            8'd144:beta_rom=8'd130; 8'd145:beta_rom=8'd130; 8'd146:beta_rom=8'd131; 8'd147:beta_rom=8'd131; 8'd148:beta_rom=8'd131; 8'd149:beta_rom=8'd132; 8'd150:beta_rom=8'd132; 8'd151:beta_rom=8'd133;
            8'd152:beta_rom=8'd133; 8'd153:beta_rom=8'd134; 8'd154:beta_rom=8'd134; 8'd155:beta_rom=8'd134; 8'd156:beta_rom=8'd135; 8'd157:beta_rom=8'd135; 8'd158:beta_rom=8'd136; 8'd159:beta_rom=8'd136;
            8'd160:beta_rom=8'd137; 8'd161:beta_rom=8'd137; 8'd162:beta_rom=8'd137; 8'd163:beta_rom=8'd138; 8'd164:beta_rom=8'd138; 8'd165:beta_rom=8'd139; 8'd166:beta_rom=8'd139; 8'd167:beta_rom=8'd140;
            8'd168:beta_rom=8'd140; 8'd169:beta_rom=8'd141; 8'd170:beta_rom=8'd141; 8'd171:beta_rom=8'd141; 8'd172:beta_rom=8'd142; 8'd173:beta_rom=8'd142; 8'd174:beta_rom=8'd143; 8'd175:beta_rom=8'd143;
            8'd176:beta_rom=8'd144; 8'd177:beta_rom=8'd144; 8'd178:beta_rom=8'd145; 8'd179:beta_rom=8'd145; 8'd180:beta_rom=8'd146; 8'd181:beta_rom=8'd146; 8'd182:beta_rom=8'd147; 8'd183:beta_rom=8'd147;
            8'd184:beta_rom=8'd148; 8'd185:beta_rom=8'd148; 8'd186:beta_rom=8'd149; 8'd187:beta_rom=8'd149; 8'd188:beta_rom=8'd150; 8'd189:beta_rom=8'd150; 8'd190:beta_rom=8'd151; 8'd191:beta_rom=8'd152;
            8'd192:beta_rom=8'd152; 8'd193:beta_rom=8'd153; 8'd194:beta_rom=8'd153; 8'd195:beta_rom=8'd154; 8'd196:beta_rom=8'd154; 8'd197:beta_rom=8'd155; 8'd198:beta_rom=8'd156; 8'd199:beta_rom=8'd156;
            8'd200:beta_rom=8'd157; 8'd201:beta_rom=8'd157; 8'd202:beta_rom=8'd158; 8'd203:beta_rom=8'd159; 8'd204:beta_rom=8'd159; 8'd205:beta_rom=8'd160; 8'd206:beta_rom=8'd161; 8'd207:beta_rom=8'd161;
            8'd208:beta_rom=8'd162; 8'd209:beta_rom=8'd163; 8'd210:beta_rom=8'd163; 8'd211:beta_rom=8'd164; 8'd212:beta_rom=8'd165; 8'd213:beta_rom=8'd166; 8'd214:beta_rom=8'd166; 8'd215:beta_rom=8'd167;
            8'd216:beta_rom=8'd168; 8'd217:beta_rom=8'd169; 8'd218:beta_rom=8'd170; 8'd219:beta_rom=8'd170; 8'd220:beta_rom=8'd171; 8'd221:beta_rom=8'd172; 8'd222:beta_rom=8'd173; 8'd223:beta_rom=8'd174;
            8'd224:beta_rom=8'd175; 8'd225:beta_rom=8'd176; 8'd226:beta_rom=8'd177; 8'd227:beta_rom=8'd178; 8'd228:beta_rom=8'd179; 8'd229:beta_rom=8'd180; 8'd230:beta_rom=8'd181; 8'd231:beta_rom=8'd182;
            8'd232:beta_rom=8'd183; 8'd233:beta_rom=8'd185; 8'd234:beta_rom=8'd186; 8'd235:beta_rom=8'd187; 8'd236:beta_rom=8'd189; 8'd237:beta_rom=8'd190; 8'd238:beta_rom=8'd192; 8'd239:beta_rom=8'd193;
            8'd240:beta_rom=8'd195; 8'd241:beta_rom=8'd197; 8'd242:beta_rom=8'd199; 8'd243:beta_rom=8'd201; 8'd244:beta_rom=8'd203; 8'd245:beta_rom=8'd205; 8'd246:beta_rom=8'd208; 8'd247:beta_rom=8'd211;
            8'd248:beta_rom=8'd214; 8'd249:beta_rom=8'd217; 8'd250:beta_rom=8'd221; 8'd251:beta_rom=8'd226; 8'd252:beta_rom=8'd232; 8'd253:beta_rom=8'd240; 8'd254:beta_rom=8'd251; 8'd255:beta_rom=8'd255;
            default: beta_rom = 8'd128;
        endcase
        3'd2: case (addr)
            8'd0:beta_rom=8'd18; 8'd1:beta_rom=8'd25; 8'd2:beta_rom=8'd28; 8'd3:beta_rom=8'd31; 8'd4:beta_rom=8'd34; 8'd5:beta_rom=8'd36; 8'd6:beta_rom=8'd37; 8'd7:beta_rom=8'd39;
            8'd8:beta_rom=8'd41; 8'd9:beta_rom=8'd42; 8'd10:beta_rom=8'd43; 8'd11:beta_rom=8'd45; 8'd12:beta_rom=8'd46; 8'd13:beta_rom=8'd47; 8'd14:beta_rom=8'd48; 8'd15:beta_rom=8'd49;
            8'd16:beta_rom=8'd50; 8'd17:beta_rom=8'd51; 8'd18:beta_rom=8'd52; 8'd19:beta_rom=8'd53; 8'd20:beta_rom=8'd54; 8'd21:beta_rom=8'd55; 8'd22:beta_rom=8'd56; 8'd23:beta_rom=8'd56;
            8'd24:beta_rom=8'd57; 8'd25:beta_rom=8'd58; 8'd26:beta_rom=8'd59; 8'd27:beta_rom=8'd60; 8'd28:beta_rom=8'd60; 8'd29:beta_rom=8'd61; 8'd30:beta_rom=8'd62; 8'd31:beta_rom=8'd63;
            8'd32:beta_rom=8'd63; 8'd33:beta_rom=8'd64; 8'd34:beta_rom=8'd65; 8'd35:beta_rom=8'd65; 8'd36:beta_rom=8'd66; 8'd37:beta_rom=8'd67; 8'd38:beta_rom=8'd67; 8'd39:beta_rom=8'd68;
            8'd40:beta_rom=8'd69; 8'd41:beta_rom=8'd69; 8'd42:beta_rom=8'd70; 8'd43:beta_rom=8'd71; 8'd44:beta_rom=8'd71; 8'd45:beta_rom=8'd72; 8'd46:beta_rom=8'd73; 8'd47:beta_rom=8'd73;
            8'd48:beta_rom=8'd74; 8'd49:beta_rom=8'd74; 8'd50:beta_rom=8'd75; 8'd51:beta_rom=8'd76; 8'd52:beta_rom=8'd76; 8'd53:beta_rom=8'd77; 8'd54:beta_rom=8'd77; 8'd55:beta_rom=8'd78;
            8'd56:beta_rom=8'd79; 8'd57:beta_rom=8'd79; 8'd58:beta_rom=8'd80; 8'd59:beta_rom=8'd80; 8'd60:beta_rom=8'd81; 8'd61:beta_rom=8'd81; 8'd62:beta_rom=8'd82; 8'd63:beta_rom=8'd83;
            8'd64:beta_rom=8'd83; 8'd65:beta_rom=8'd84; 8'd66:beta_rom=8'd84; 8'd67:beta_rom=8'd85; 8'd68:beta_rom=8'd85; 8'd69:beta_rom=8'd86; 8'd70:beta_rom=8'd86; 8'd71:beta_rom=8'd87;
            8'd72:beta_rom=8'd88; 8'd73:beta_rom=8'd88; 8'd74:beta_rom=8'd89; 8'd75:beta_rom=8'd89; 8'd76:beta_rom=8'd90; 8'd77:beta_rom=8'd90; 8'd78:beta_rom=8'd91; 8'd79:beta_rom=8'd91;
            8'd80:beta_rom=8'd92; 8'd81:beta_rom=8'd93; 8'd82:beta_rom=8'd93; 8'd83:beta_rom=8'd94; 8'd84:beta_rom=8'd94; 8'd85:beta_rom=8'd95; 8'd86:beta_rom=8'd95; 8'd87:beta_rom=8'd96;
            8'd88:beta_rom=8'd96; 8'd89:beta_rom=8'd97; 8'd90:beta_rom=8'd97; 8'd91:beta_rom=8'd98; 8'd92:beta_rom=8'd98; 8'd93:beta_rom=8'd99; 8'd94:beta_rom=8'd100; 8'd95:beta_rom=8'd100;
            8'd96:beta_rom=8'd101; 8'd97:beta_rom=8'd101; 8'd98:beta_rom=8'd102; 8'd99:beta_rom=8'd102; 8'd100:beta_rom=8'd103; 8'd101:beta_rom=8'd103; 8'd102:beta_rom=8'd104; 8'd103:beta_rom=8'd104;
            8'd104:beta_rom=8'd105; 8'd105:beta_rom=8'd105; 8'd106:beta_rom=8'd106; 8'd107:beta_rom=8'd107; 8'd108:beta_rom=8'd107; 8'd109:beta_rom=8'd108; 8'd110:beta_rom=8'd108; 8'd111:beta_rom=8'd109;
            8'd112:beta_rom=8'd109; 8'd113:beta_rom=8'd110; 8'd114:beta_rom=8'd110; 8'd115:beta_rom=8'd111; 8'd116:beta_rom=8'd111; 8'd117:beta_rom=8'd112; 8'd118:beta_rom=8'd113; 8'd119:beta_rom=8'd113;
            8'd120:beta_rom=8'd114; 8'd121:beta_rom=8'd114; 8'd122:beta_rom=8'd115; 8'd123:beta_rom=8'd115; 8'd124:beta_rom=8'd116; 8'd125:beta_rom=8'd117; 8'd126:beta_rom=8'd117; 8'd127:beta_rom=8'd118;
            8'd128:beta_rom=8'd118; 8'd129:beta_rom=8'd119; 8'd130:beta_rom=8'd119; 8'd131:beta_rom=8'd120; 8'd132:beta_rom=8'd121; 8'd133:beta_rom=8'd121; 8'd134:beta_rom=8'd122; 8'd135:beta_rom=8'd122;
            8'd136:beta_rom=8'd123; 8'd137:beta_rom=8'd123; 8'd138:beta_rom=8'd124; 8'd139:beta_rom=8'd125; 8'd140:beta_rom=8'd125; 8'd141:beta_rom=8'd126; 8'd142:beta_rom=8'd126; 8'd143:beta_rom=8'd127;
            8'd144:beta_rom=8'd128; 8'd145:beta_rom=8'd128; 8'd146:beta_rom=8'd129; 8'd147:beta_rom=8'd129; 8'd148:beta_rom=8'd130; 8'd149:beta_rom=8'd131; 8'd150:beta_rom=8'd131; 8'd151:beta_rom=8'd132;
            8'd152:beta_rom=8'd133; 8'd153:beta_rom=8'd133; 8'd154:beta_rom=8'd134; 8'd155:beta_rom=8'd135; 8'd156:beta_rom=8'd135; 8'd157:beta_rom=8'd136; 8'd158:beta_rom=8'd137; 8'd159:beta_rom=8'd137;
            8'd160:beta_rom=8'd138; 8'd161:beta_rom=8'd139; 8'd162:beta_rom=8'd139; 8'd163:beta_rom=8'd140; 8'd164:beta_rom=8'd141; 8'd165:beta_rom=8'd141; 8'd166:beta_rom=8'd142; 8'd167:beta_rom=8'd143;
            8'd168:beta_rom=8'd143; 8'd169:beta_rom=8'd144; 8'd170:beta_rom=8'd145; 8'd171:beta_rom=8'd145; 8'd172:beta_rom=8'd146; 8'd173:beta_rom=8'd147; 8'd174:beta_rom=8'd148; 8'd175:beta_rom=8'd148;
            8'd176:beta_rom=8'd149; 8'd177:beta_rom=8'd150; 8'd178:beta_rom=8'd151; 8'd179:beta_rom=8'd151; 8'd180:beta_rom=8'd152; 8'd181:beta_rom=8'd153; 8'd182:beta_rom=8'd154; 8'd183:beta_rom=8'd155;
            8'd184:beta_rom=8'd155; 8'd185:beta_rom=8'd156; 8'd186:beta_rom=8'd157; 8'd187:beta_rom=8'd158; 8'd188:beta_rom=8'd159; 8'd189:beta_rom=8'd160; 8'd190:beta_rom=8'd160; 8'd191:beta_rom=8'd161;
            8'd192:beta_rom=8'd162; 8'd193:beta_rom=8'd163; 8'd194:beta_rom=8'd164; 8'd195:beta_rom=8'd165; 8'd196:beta_rom=8'd166; 8'd197:beta_rom=8'd167; 8'd198:beta_rom=8'd168; 8'd199:beta_rom=8'd169;
            8'd200:beta_rom=8'd170; 8'd201:beta_rom=8'd171; 8'd202:beta_rom=8'd172; 8'd203:beta_rom=8'd173; 8'd204:beta_rom=8'd174; 8'd205:beta_rom=8'd175; 8'd206:beta_rom=8'd176; 8'd207:beta_rom=8'd177;
            8'd208:beta_rom=8'd178; 8'd209:beta_rom=8'd179; 8'd210:beta_rom=8'd180; 8'd211:beta_rom=8'd182; 8'd212:beta_rom=8'd183; 8'd213:beta_rom=8'd184; 8'd214:beta_rom=8'd185; 8'd215:beta_rom=8'd186;
            8'd216:beta_rom=8'd188; 8'd217:beta_rom=8'd189; 8'd218:beta_rom=8'd190; 8'd219:beta_rom=8'd192; 8'd220:beta_rom=8'd193; 8'd221:beta_rom=8'd195; 8'd222:beta_rom=8'd196; 8'd223:beta_rom=8'd198;
            8'd224:beta_rom=8'd199; 8'd225:beta_rom=8'd201; 8'd226:beta_rom=8'd202; 8'd227:beta_rom=8'd204; 8'd228:beta_rom=8'd206; 8'd229:beta_rom=8'd208; 8'd230:beta_rom=8'd209; 8'd231:beta_rom=8'd211;
            8'd232:beta_rom=8'd213; 8'd233:beta_rom=8'd215; 8'd234:beta_rom=8'd218; 8'd235:beta_rom=8'd220; 8'd236:beta_rom=8'd222; 8'd237:beta_rom=8'd225; 8'd238:beta_rom=8'd227; 8'd239:beta_rom=8'd230;
            8'd240:beta_rom=8'd233; 8'd241:beta_rom=8'd236; 8'd242:beta_rom=8'd239; 8'd243:beta_rom=8'd243; 8'd244:beta_rom=8'd246; 8'd245:beta_rom=8'd250; 8'd246:beta_rom=8'd255; 8'd247:beta_rom=8'd255;
            8'd248:beta_rom=8'd255; 8'd249:beta_rom=8'd255; 8'd250:beta_rom=8'd255; 8'd251:beta_rom=8'd255; 8'd252:beta_rom=8'd255; 8'd253:beta_rom=8'd255; 8'd254:beta_rom=8'd255; 8'd255:beta_rom=8'd255;
            default: beta_rom = 8'd128;
        endcase
        3'd3: case (addr)
            8'd0:beta_rom=8'd5; 8'd1:beta_rom=8'd9; 8'd2:beta_rom=8'd11; 8'd3:beta_rom=8'd13; 8'd4:beta_rom=8'd15; 8'd5:beta_rom=8'd17; 8'd6:beta_rom=8'd18; 8'd7:beta_rom=8'd20;
            8'd8:beta_rom=8'd21; 8'd9:beta_rom=8'd22; 8'd10:beta_rom=8'd23; 8'd11:beta_rom=8'd25; 8'd12:beta_rom=8'd26; 8'd13:beta_rom=8'd27; 8'd14:beta_rom=8'd28; 8'd15:beta_rom=8'd29;
            8'd16:beta_rom=8'd30; 8'd17:beta_rom=8'd31; 8'd18:beta_rom=8'd32; 8'd19:beta_rom=8'd32; 8'd20:beta_rom=8'd33; 8'd21:beta_rom=8'd34; 8'd22:beta_rom=8'd35; 8'd23:beta_rom=8'd36;
            8'd24:beta_rom=8'd37; 8'd25:beta_rom=8'd38; 8'd26:beta_rom=8'd38; 8'd27:beta_rom=8'd39; 8'd28:beta_rom=8'd40; 8'd29:beta_rom=8'd41; 8'd30:beta_rom=8'd41; 8'd31:beta_rom=8'd42;
            8'd32:beta_rom=8'd43; 8'd33:beta_rom=8'd44; 8'd34:beta_rom=8'd45; 8'd35:beta_rom=8'd45; 8'd36:beta_rom=8'd46; 8'd37:beta_rom=8'd47; 8'd38:beta_rom=8'd47; 8'd39:beta_rom=8'd48;
            8'd40:beta_rom=8'd49; 8'd41:beta_rom=8'd50; 8'd42:beta_rom=8'd50; 8'd43:beta_rom=8'd51; 8'd44:beta_rom=8'd52; 8'd45:beta_rom=8'd52; 8'd46:beta_rom=8'd53; 8'd47:beta_rom=8'd54;
            8'd48:beta_rom=8'd55; 8'd49:beta_rom=8'd55; 8'd50:beta_rom=8'd56; 8'd51:beta_rom=8'd57; 8'd52:beta_rom=8'd57; 8'd53:beta_rom=8'd58; 8'd54:beta_rom=8'd59; 8'd55:beta_rom=8'd59;
            8'd56:beta_rom=8'd60; 8'd57:beta_rom=8'd61; 8'd58:beta_rom=8'd61; 8'd59:beta_rom=8'd62; 8'd60:beta_rom=8'd63; 8'd61:beta_rom=8'd63; 8'd62:beta_rom=8'd64; 8'd63:beta_rom=8'd65;
            8'd64:beta_rom=8'd65; 8'd65:beta_rom=8'd66; 8'd66:beta_rom=8'd67; 8'd67:beta_rom=8'd67; 8'd68:beta_rom=8'd68; 8'd69:beta_rom=8'd69; 8'd70:beta_rom=8'd69; 8'd71:beta_rom=8'd70;
            8'd72:beta_rom=8'd71; 8'd73:beta_rom=8'd71; 8'd74:beta_rom=8'd72; 8'd75:beta_rom=8'd73; 8'd76:beta_rom=8'd73; 8'd77:beta_rom=8'd74; 8'd78:beta_rom=8'd75; 8'd79:beta_rom=8'd75;
            8'd80:beta_rom=8'd76; 8'd81:beta_rom=8'd77; 8'd82:beta_rom=8'd77; 8'd83:beta_rom=8'd78; 8'd84:beta_rom=8'd79; 8'd85:beta_rom=8'd79; 8'd86:beta_rom=8'd80; 8'd87:beta_rom=8'd81;
            8'd88:beta_rom=8'd81; 8'd89:beta_rom=8'd82; 8'd90:beta_rom=8'd83; 8'd91:beta_rom=8'd83; 8'd92:beta_rom=8'd84; 8'd93:beta_rom=8'd85; 8'd94:beta_rom=8'd85; 8'd95:beta_rom=8'd86;
            8'd96:beta_rom=8'd87; 8'd97:beta_rom=8'd87; 8'd98:beta_rom=8'd88; 8'd99:beta_rom=8'd89; 8'd100:beta_rom=8'd89; 8'd101:beta_rom=8'd90; 8'd102:beta_rom=8'd91; 8'd103:beta_rom=8'd92;
            8'd104:beta_rom=8'd92; 8'd105:beta_rom=8'd93; 8'd106:beta_rom=8'd94; 8'd107:beta_rom=8'd94; 8'd108:beta_rom=8'd95; 8'd109:beta_rom=8'd96; 8'd110:beta_rom=8'd96; 8'd111:beta_rom=8'd97;
            8'd112:beta_rom=8'd98; 8'd113:beta_rom=8'd99; 8'd114:beta_rom=8'd99; 8'd115:beta_rom=8'd100; 8'd116:beta_rom=8'd101; 8'd117:beta_rom=8'd101; 8'd118:beta_rom=8'd102; 8'd119:beta_rom=8'd103;
            8'd120:beta_rom=8'd104; 8'd121:beta_rom=8'd104; 8'd122:beta_rom=8'd105; 8'd123:beta_rom=8'd106; 8'd124:beta_rom=8'd107; 8'd125:beta_rom=8'd107; 8'd126:beta_rom=8'd108; 8'd127:beta_rom=8'd109;
            8'd128:beta_rom=8'd110; 8'd129:beta_rom=8'd110; 8'd130:beta_rom=8'd111; 8'd131:beta_rom=8'd112; 8'd132:beta_rom=8'd113; 8'd133:beta_rom=8'd114; 8'd134:beta_rom=8'd114; 8'd135:beta_rom=8'd115;
            8'd136:beta_rom=8'd116; 8'd137:beta_rom=8'd117; 8'd138:beta_rom=8'd117; 8'd139:beta_rom=8'd118; 8'd140:beta_rom=8'd119; 8'd141:beta_rom=8'd120; 8'd142:beta_rom=8'd121; 8'd143:beta_rom=8'd122;
            8'd144:beta_rom=8'd122; 8'd145:beta_rom=8'd123; 8'd146:beta_rom=8'd124; 8'd147:beta_rom=8'd125; 8'd148:beta_rom=8'd126; 8'd149:beta_rom=8'd127; 8'd150:beta_rom=8'd127; 8'd151:beta_rom=8'd128;
            8'd152:beta_rom=8'd129; 8'd153:beta_rom=8'd130; 8'd154:beta_rom=8'd131; 8'd155:beta_rom=8'd132; 8'd156:beta_rom=8'd133; 8'd157:beta_rom=8'd134; 8'd158:beta_rom=8'd135; 8'd159:beta_rom=8'd135;
            8'd160:beta_rom=8'd136; 8'd161:beta_rom=8'd137; 8'd162:beta_rom=8'd138; 8'd163:beta_rom=8'd139; 8'd164:beta_rom=8'd140; 8'd165:beta_rom=8'd141; 8'd166:beta_rom=8'd142; 8'd167:beta_rom=8'd143;
            8'd168:beta_rom=8'd144; 8'd169:beta_rom=8'd145; 8'd170:beta_rom=8'd146; 8'd171:beta_rom=8'd147; 8'd172:beta_rom=8'd148; 8'd173:beta_rom=8'd149; 8'd174:beta_rom=8'd150; 8'd175:beta_rom=8'd151;
            8'd176:beta_rom=8'd152; 8'd177:beta_rom=8'd153; 8'd178:beta_rom=8'd154; 8'd179:beta_rom=8'd156; 8'd180:beta_rom=8'd157; 8'd181:beta_rom=8'd158; 8'd182:beta_rom=8'd159; 8'd183:beta_rom=8'd160;
            8'd184:beta_rom=8'd161; 8'd185:beta_rom=8'd162; 8'd186:beta_rom=8'd164; 8'd187:beta_rom=8'd165; 8'd188:beta_rom=8'd166; 8'd189:beta_rom=8'd167; 8'd190:beta_rom=8'd168; 8'd191:beta_rom=8'd170;
            8'd192:beta_rom=8'd171; 8'd193:beta_rom=8'd172; 8'd194:beta_rom=8'd174; 8'd195:beta_rom=8'd175; 8'd196:beta_rom=8'd176; 8'd197:beta_rom=8'd178; 8'd198:beta_rom=8'd179; 8'd199:beta_rom=8'd180;
            8'd200:beta_rom=8'd182; 8'd201:beta_rom=8'd183; 8'd202:beta_rom=8'd185; 8'd203:beta_rom=8'd186; 8'd204:beta_rom=8'd188; 8'd205:beta_rom=8'd189; 8'd206:beta_rom=8'd191; 8'd207:beta_rom=8'd193;
            8'd208:beta_rom=8'd194; 8'd209:beta_rom=8'd196; 8'd210:beta_rom=8'd198; 8'd211:beta_rom=8'd199; 8'd212:beta_rom=8'd201; 8'd213:beta_rom=8'd203; 8'd214:beta_rom=8'd205; 8'd215:beta_rom=8'd207;
            8'd216:beta_rom=8'd209; 8'd217:beta_rom=8'd210; 8'd218:beta_rom=8'd213; 8'd219:beta_rom=8'd215; 8'd220:beta_rom=8'd217; 8'd221:beta_rom=8'd219; 8'd222:beta_rom=8'd221; 8'd223:beta_rom=8'd223;
            8'd224:beta_rom=8'd226; 8'd225:beta_rom=8'd228; 8'd226:beta_rom=8'd231; 8'd227:beta_rom=8'd233; 8'd228:beta_rom=8'd236; 8'd229:beta_rom=8'd239; 8'd230:beta_rom=8'd242; 8'd231:beta_rom=8'd244;
            8'd232:beta_rom=8'd248; 8'd233:beta_rom=8'd251; 8'd234:beta_rom=8'd254; 8'd235:beta_rom=8'd255; 8'd236:beta_rom=8'd255; 8'd237:beta_rom=8'd255; 8'd238:beta_rom=8'd255; 8'd239:beta_rom=8'd255;
            8'd240:beta_rom=8'd255; 8'd241:beta_rom=8'd255; 8'd242:beta_rom=8'd255; 8'd243:beta_rom=8'd255; 8'd244:beta_rom=8'd255; 8'd245:beta_rom=8'd255; 8'd246:beta_rom=8'd255; 8'd247:beta_rom=8'd255;
            8'd248:beta_rom=8'd255; 8'd249:beta_rom=8'd255; 8'd250:beta_rom=8'd255; 8'd251:beta_rom=8'd255; 8'd252:beta_rom=8'd255; 8'd253:beta_rom=8'd255; 8'd254:beta_rom=8'd255; 8'd255:beta_rom=8'd255;
            default: beta_rom = 8'd128;
        endcase
        3'd4: case (addr)
            8'd0:beta_rom=8'd1; 8'd1:beta_rom=8'd2; 8'd2:beta_rom=8'd4; 8'd3:beta_rom=8'd5; 8'd4:beta_rom=8'd6; 8'd5:beta_rom=8'd7; 8'd6:beta_rom=8'd8; 8'd7:beta_rom=8'd9;
            8'd8:beta_rom=8'd10; 8'd9:beta_rom=8'd11; 8'd10:beta_rom=8'd12; 8'd11:beta_rom=8'd12; 8'd12:beta_rom=8'd13; 8'd13:beta_rom=8'd14; 8'd14:beta_rom=8'd15; 8'd15:beta_rom=8'd16;
            8'd16:beta_rom=8'd16; 8'd17:beta_rom=8'd17; 8'd18:beta_rom=8'd18; 8'd19:beta_rom=8'd19; 8'd20:beta_rom=8'd19; 8'd21:beta_rom=8'd20; 8'd22:beta_rom=8'd21; 8'd23:beta_rom=8'd22;
            8'd24:beta_rom=8'd22; 8'd25:beta_rom=8'd23; 8'd26:beta_rom=8'd24; 8'd27:beta_rom=8'd24; 8'd28:beta_rom=8'd25; 8'd29:beta_rom=8'd26; 8'd30:beta_rom=8'd27; 8'd31:beta_rom=8'd27;
            8'd32:beta_rom=8'd28; 8'd33:beta_rom=8'd29; 8'd34:beta_rom=8'd29; 8'd35:beta_rom=8'd30; 8'd36:beta_rom=8'd31; 8'd37:beta_rom=8'd31; 8'd38:beta_rom=8'd32; 8'd39:beta_rom=8'd33;
            8'd40:beta_rom=8'd33; 8'd41:beta_rom=8'd34; 8'd42:beta_rom=8'd35; 8'd43:beta_rom=8'd36; 8'd44:beta_rom=8'd36; 8'd45:beta_rom=8'd37; 8'd46:beta_rom=8'd38; 8'd47:beta_rom=8'd38;
            8'd48:beta_rom=8'd39; 8'd49:beta_rom=8'd40; 8'd50:beta_rom=8'd40; 8'd51:beta_rom=8'd41; 8'd52:beta_rom=8'd42; 8'd53:beta_rom=8'd42; 8'd54:beta_rom=8'd43; 8'd55:beta_rom=8'd44;
            8'd56:beta_rom=8'd44; 8'd57:beta_rom=8'd45; 8'd58:beta_rom=8'd46; 8'd59:beta_rom=8'd47; 8'd60:beta_rom=8'd47; 8'd61:beta_rom=8'd48; 8'd62:beta_rom=8'd49; 8'd63:beta_rom=8'd49;
            8'd64:beta_rom=8'd50; 8'd65:beta_rom=8'd51; 8'd66:beta_rom=8'd51; 8'd67:beta_rom=8'd52; 8'd68:beta_rom=8'd53; 8'd69:beta_rom=8'd54; 8'd70:beta_rom=8'd54; 8'd71:beta_rom=8'd55;
            8'd72:beta_rom=8'd56; 8'd73:beta_rom=8'd56; 8'd74:beta_rom=8'd57; 8'd75:beta_rom=8'd58; 8'd76:beta_rom=8'd58; 8'd77:beta_rom=8'd59; 8'd78:beta_rom=8'd60; 8'd79:beta_rom=8'd61;
            8'd80:beta_rom=8'd61; 8'd81:beta_rom=8'd62; 8'd82:beta_rom=8'd63; 8'd83:beta_rom=8'd64; 8'd84:beta_rom=8'd64; 8'd85:beta_rom=8'd65; 8'd86:beta_rom=8'd66; 8'd87:beta_rom=8'd66;
            8'd88:beta_rom=8'd67; 8'd89:beta_rom=8'd68; 8'd90:beta_rom=8'd69; 8'd91:beta_rom=8'd69; 8'd92:beta_rom=8'd70; 8'd93:beta_rom=8'd71; 8'd94:beta_rom=8'd72; 8'd95:beta_rom=8'd72;
            8'd96:beta_rom=8'd73; 8'd97:beta_rom=8'd74; 8'd98:beta_rom=8'd75; 8'd99:beta_rom=8'd76; 8'd100:beta_rom=8'd76; 8'd101:beta_rom=8'd77; 8'd102:beta_rom=8'd78; 8'd103:beta_rom=8'd79;
            8'd104:beta_rom=8'd79; 8'd105:beta_rom=8'd80; 8'd106:beta_rom=8'd81; 8'd107:beta_rom=8'd82; 8'd108:beta_rom=8'd83; 8'd109:beta_rom=8'd84; 8'd110:beta_rom=8'd84; 8'd111:beta_rom=8'd85;
            8'd112:beta_rom=8'd86; 8'd113:beta_rom=8'd87; 8'd114:beta_rom=8'd88; 8'd115:beta_rom=8'd88; 8'd116:beta_rom=8'd89; 8'd117:beta_rom=8'd90; 8'd118:beta_rom=8'd91; 8'd119:beta_rom=8'd92;
            8'd120:beta_rom=8'd93; 8'd121:beta_rom=8'd94; 8'd122:beta_rom=8'd94; 8'd123:beta_rom=8'd95; 8'd124:beta_rom=8'd96; 8'd125:beta_rom=8'd97; 8'd126:beta_rom=8'd98; 8'd127:beta_rom=8'd99;
            8'd128:beta_rom=8'd100; 8'd129:beta_rom=8'd101; 8'd130:beta_rom=8'd102; 8'd131:beta_rom=8'd102; 8'd132:beta_rom=8'd103; 8'd133:beta_rom=8'd104; 8'd134:beta_rom=8'd105; 8'd135:beta_rom=8'd106;
            8'd136:beta_rom=8'd107; 8'd137:beta_rom=8'd108; 8'd138:beta_rom=8'd109; 8'd139:beta_rom=8'd110; 8'd140:beta_rom=8'd111; 8'd141:beta_rom=8'd112; 8'd142:beta_rom=8'd113; 8'd143:beta_rom=8'd114;
            8'd144:beta_rom=8'd115; 8'd145:beta_rom=8'd116; 8'd146:beta_rom=8'd117; 8'd147:beta_rom=8'd118; 8'd148:beta_rom=8'd119; 8'd149:beta_rom=8'd120; 8'd150:beta_rom=8'd121; 8'd151:beta_rom=8'd122;
            8'd152:beta_rom=8'd123; 8'd153:beta_rom=8'd124; 8'd154:beta_rom=8'd125; 8'd155:beta_rom=8'd127; 8'd156:beta_rom=8'd128; 8'd157:beta_rom=8'd129; 8'd158:beta_rom=8'd130; 8'd159:beta_rom=8'd131;
            8'd160:beta_rom=8'd132; 8'd161:beta_rom=8'd133; 8'd162:beta_rom=8'd134; 8'd163:beta_rom=8'd136; 8'd164:beta_rom=8'd137; 8'd165:beta_rom=8'd138; 8'd166:beta_rom=8'd139; 8'd167:beta_rom=8'd140;
            8'd168:beta_rom=8'd142; 8'd169:beta_rom=8'd143; 8'd170:beta_rom=8'd144; 8'd171:beta_rom=8'd146; 8'd172:beta_rom=8'd147; 8'd173:beta_rom=8'd148; 8'd174:beta_rom=8'd149; 8'd175:beta_rom=8'd151;
            8'd176:beta_rom=8'd152; 8'd177:beta_rom=8'd153; 8'd178:beta_rom=8'd155; 8'd179:beta_rom=8'd156; 8'd180:beta_rom=8'd158; 8'd181:beta_rom=8'd159; 8'd182:beta_rom=8'd160; 8'd183:beta_rom=8'd162;
            8'd184:beta_rom=8'd163; 8'd185:beta_rom=8'd165; 8'd186:beta_rom=8'd166; 8'd187:beta_rom=8'd168; 8'd188:beta_rom=8'd170; 8'd189:beta_rom=8'd171; 8'd190:beta_rom=8'd173; 8'd191:beta_rom=8'd174;
            8'd192:beta_rom=8'd176; 8'd193:beta_rom=8'd178; 8'd194:beta_rom=8'd179; 8'd195:beta_rom=8'd181; 8'd196:beta_rom=8'd183; 8'd197:beta_rom=8'd185; 8'd198:beta_rom=8'd186; 8'd199:beta_rom=8'd188;
            8'd200:beta_rom=8'd190; 8'd201:beta_rom=8'd192; 8'd202:beta_rom=8'd194; 8'd203:beta_rom=8'd196; 8'd204:beta_rom=8'd198; 8'd205:beta_rom=8'd200; 8'd206:beta_rom=8'd202; 8'd207:beta_rom=8'd204;
            8'd208:beta_rom=8'd206; 8'd209:beta_rom=8'd208; 8'd210:beta_rom=8'd211; 8'd211:beta_rom=8'd213; 8'd212:beta_rom=8'd215; 8'd213:beta_rom=8'd218; 8'd214:beta_rom=8'd220; 8'd215:beta_rom=8'd223;
            8'd216:beta_rom=8'd225; 8'd217:beta_rom=8'd228; 8'd218:beta_rom=8'd231; 8'd219:beta_rom=8'd233; 8'd220:beta_rom=8'd236; 8'd221:beta_rom=8'd239; 8'd222:beta_rom=8'd242; 8'd223:beta_rom=8'd245;
            8'd224:beta_rom=8'd248; 8'd225:beta_rom=8'd251; 8'd226:beta_rom=8'd255; 8'd227:beta_rom=8'd255; 8'd228:beta_rom=8'd255; 8'd229:beta_rom=8'd255; 8'd230:beta_rom=8'd255; 8'd231:beta_rom=8'd255;
            8'd232:beta_rom=8'd255; 8'd233:beta_rom=8'd255; 8'd234:beta_rom=8'd255; 8'd235:beta_rom=8'd255; 8'd236:beta_rom=8'd255; 8'd237:beta_rom=8'd255; 8'd238:beta_rom=8'd255; 8'd239:beta_rom=8'd255;
            8'd240:beta_rom=8'd255; 8'd241:beta_rom=8'd255; 8'd242:beta_rom=8'd255; 8'd243:beta_rom=8'd255; 8'd244:beta_rom=8'd255; 8'd245:beta_rom=8'd255; 8'd246:beta_rom=8'd255; 8'd247:beta_rom=8'd255;
            8'd248:beta_rom=8'd255; 8'd249:beta_rom=8'd255; 8'd250:beta_rom=8'd255; 8'd251:beta_rom=8'd255; 8'd252:beta_rom=8'd255; 8'd253:beta_rom=8'd255; 8'd254:beta_rom=8'd255; 8'd255:beta_rom=8'd255;
            default: beta_rom = 8'd128;
        endcase
        3'd5: case (addr)
            8'd0:beta_rom=8'd0; 8'd1:beta_rom=8'd1; 8'd2:beta_rom=8'd2; 8'd3:beta_rom=8'd2; 8'd4:beta_rom=8'd3; 8'd5:beta_rom=8'd4; 8'd6:beta_rom=8'd4; 8'd7:beta_rom=8'd5;
            8'd8:beta_rom=8'd6; 8'd9:beta_rom=8'd6; 8'd10:beta_rom=8'd7; 8'd11:beta_rom=8'd7; 8'd12:beta_rom=8'd8; 8'd13:beta_rom=8'd9; 8'd14:beta_rom=8'd9; 8'd15:beta_rom=8'd10;
            8'd16:beta_rom=8'd11; 8'd17:beta_rom=8'd11; 8'd18:beta_rom=8'd12; 8'd19:beta_rom=8'd12; 8'd20:beta_rom=8'd13; 8'd21:beta_rom=8'd14; 8'd22:beta_rom=8'd14; 8'd23:beta_rom=8'd15;
            8'd24:beta_rom=8'd16; 8'd25:beta_rom=8'd16; 8'd26:beta_rom=8'd17; 8'd27:beta_rom=8'd17; 8'd28:beta_rom=8'd18; 8'd29:beta_rom=8'd19; 8'd30:beta_rom=8'd19; 8'd31:beta_rom=8'd20;
            8'd32:beta_rom=8'd21; 8'd33:beta_rom=8'd21; 8'd34:beta_rom=8'd22; 8'd35:beta_rom=8'd22; 8'd36:beta_rom=8'd23; 8'd37:beta_rom=8'd24; 8'd38:beta_rom=8'd24; 8'd39:beta_rom=8'd25;
            8'd40:beta_rom=8'd26; 8'd41:beta_rom=8'd26; 8'd42:beta_rom=8'd27; 8'd43:beta_rom=8'd27; 8'd44:beta_rom=8'd28; 8'd45:beta_rom=8'd29; 8'd46:beta_rom=8'd29; 8'd47:beta_rom=8'd30;
            8'd48:beta_rom=8'd31; 8'd49:beta_rom=8'd31; 8'd50:beta_rom=8'd32; 8'd51:beta_rom=8'd33; 8'd52:beta_rom=8'd33; 8'd53:beta_rom=8'd34; 8'd54:beta_rom=8'd35; 8'd55:beta_rom=8'd35;
            8'd56:beta_rom=8'd36; 8'd57:beta_rom=8'd37; 8'd58:beta_rom=8'd37; 8'd59:beta_rom=8'd38; 8'd60:beta_rom=8'd39; 8'd61:beta_rom=8'd39; 8'd62:beta_rom=8'd40; 8'd63:beta_rom=8'd41;
            8'd64:beta_rom=8'd41; 8'd65:beta_rom=8'd42; 8'd66:beta_rom=8'd43; 8'd67:beta_rom=8'd43; 8'd68:beta_rom=8'd44; 8'd69:beta_rom=8'd45; 8'd70:beta_rom=8'd46; 8'd71:beta_rom=8'd46;
            8'd72:beta_rom=8'd47; 8'd73:beta_rom=8'd48; 8'd74:beta_rom=8'd48; 8'd75:beta_rom=8'd49; 8'd76:beta_rom=8'd50; 8'd77:beta_rom=8'd51; 8'd78:beta_rom=8'd51; 8'd79:beta_rom=8'd52;
            8'd80:beta_rom=8'd53; 8'd81:beta_rom=8'd53; 8'd82:beta_rom=8'd54; 8'd83:beta_rom=8'd55; 8'd84:beta_rom=8'd56; 8'd85:beta_rom=8'd56; 8'd86:beta_rom=8'd57; 8'd87:beta_rom=8'd58;
            8'd88:beta_rom=8'd59; 8'd89:beta_rom=8'd59; 8'd90:beta_rom=8'd60; 8'd91:beta_rom=8'd61; 8'd92:beta_rom=8'd62; 8'd93:beta_rom=8'd63; 8'd94:beta_rom=8'd63; 8'd95:beta_rom=8'd64;
            8'd96:beta_rom=8'd65; 8'd97:beta_rom=8'd66; 8'd98:beta_rom=8'd66; 8'd99:beta_rom=8'd67; 8'd100:beta_rom=8'd68; 8'd101:beta_rom=8'd69; 8'd102:beta_rom=8'd70; 8'd103:beta_rom=8'd71;
            8'd104:beta_rom=8'd71; 8'd105:beta_rom=8'd72; 8'd106:beta_rom=8'd73; 8'd107:beta_rom=8'd74; 8'd108:beta_rom=8'd75; 8'd109:beta_rom=8'd76; 8'd110:beta_rom=8'd76; 8'd111:beta_rom=8'd77;
            8'd112:beta_rom=8'd78; 8'd113:beta_rom=8'd79; 8'd114:beta_rom=8'd80; 8'd115:beta_rom=8'd81; 8'd116:beta_rom=8'd82; 8'd117:beta_rom=8'd83; 8'd118:beta_rom=8'd84; 8'd119:beta_rom=8'd84;
            8'd120:beta_rom=8'd85; 8'd121:beta_rom=8'd86; 8'd122:beta_rom=8'd87; 8'd123:beta_rom=8'd88; 8'd124:beta_rom=8'd89; 8'd125:beta_rom=8'd90; 8'd126:beta_rom=8'd91; 8'd127:beta_rom=8'd92;
            8'd128:beta_rom=8'd93; 8'd129:beta_rom=8'd94; 8'd130:beta_rom=8'd95; 8'd131:beta_rom=8'd96; 8'd132:beta_rom=8'd97; 8'd133:beta_rom=8'd98; 8'd134:beta_rom=8'd99; 8'd135:beta_rom=8'd100;
            8'd136:beta_rom=8'd101; 8'd137:beta_rom=8'd102; 8'd138:beta_rom=8'd103; 8'd139:beta_rom=8'd104; 8'd140:beta_rom=8'd105; 8'd141:beta_rom=8'd106; 8'd142:beta_rom=8'd107; 8'd143:beta_rom=8'd108;
            8'd144:beta_rom=8'd109; 8'd145:beta_rom=8'd111; 8'd146:beta_rom=8'd112; 8'd147:beta_rom=8'd113; 8'd148:beta_rom=8'd114; 8'd149:beta_rom=8'd115; 8'd150:beta_rom=8'd116; 8'd151:beta_rom=8'd117;
            8'd152:beta_rom=8'd119; 8'd153:beta_rom=8'd120; 8'd154:beta_rom=8'd121; 8'd155:beta_rom=8'd122; 8'd156:beta_rom=8'd123; 8'd157:beta_rom=8'd125; 8'd158:beta_rom=8'd126; 8'd159:beta_rom=8'd127;
            8'd160:beta_rom=8'd128; 8'd161:beta_rom=8'd130; 8'd162:beta_rom=8'd131; 8'd163:beta_rom=8'd132; 8'd164:beta_rom=8'd134; 8'd165:beta_rom=8'd135; 8'd166:beta_rom=8'd136; 8'd167:beta_rom=8'd138;
            8'd168:beta_rom=8'd139; 8'd169:beta_rom=8'd140; 8'd170:beta_rom=8'd142; 8'd171:beta_rom=8'd143; 8'd172:beta_rom=8'd145; 8'd173:beta_rom=8'd146; 8'd174:beta_rom=8'd148; 8'd175:beta_rom=8'd149;
            8'd176:beta_rom=8'd151; 8'd177:beta_rom=8'd152; 8'd178:beta_rom=8'd154; 8'd179:beta_rom=8'd155; 8'd180:beta_rom=8'd157; 8'd181:beta_rom=8'd158; 8'd182:beta_rom=8'd160; 8'd183:beta_rom=8'd162;
            8'd184:beta_rom=8'd163; 8'd185:beta_rom=8'd165; 8'd186:beta_rom=8'd167; 8'd187:beta_rom=8'd168; 8'd188:beta_rom=8'd170; 8'd189:beta_rom=8'd172; 8'd190:beta_rom=8'd174; 8'd191:beta_rom=8'd176;
            8'd192:beta_rom=8'd178; 8'd193:beta_rom=8'd179; 8'd194:beta_rom=8'd181; 8'd195:beta_rom=8'd183; 8'd196:beta_rom=8'd185; 8'd197:beta_rom=8'd187; 8'd198:beta_rom=8'd189; 8'd199:beta_rom=8'd192;
            8'd200:beta_rom=8'd194; 8'd201:beta_rom=8'd196; 8'd202:beta_rom=8'd198; 8'd203:beta_rom=8'd200; 8'd204:beta_rom=8'd203; 8'd205:beta_rom=8'd205; 8'd206:beta_rom=8'd207; 8'd207:beta_rom=8'd210;
            8'd208:beta_rom=8'd212; 8'd209:beta_rom=8'd215; 8'd210:beta_rom=8'd217; 8'd211:beta_rom=8'd220; 8'd212:beta_rom=8'd223; 8'd213:beta_rom=8'd225; 8'd214:beta_rom=8'd228; 8'd215:beta_rom=8'd231;
            8'd216:beta_rom=8'd234; 8'd217:beta_rom=8'd237; 8'd218:beta_rom=8'd240; 8'd219:beta_rom=8'd243; 8'd220:beta_rom=8'd247; 8'd221:beta_rom=8'd250; 8'd222:beta_rom=8'd254; 8'd223:beta_rom=8'd255;
            8'd224:beta_rom=8'd255; 8'd225:beta_rom=8'd255; 8'd226:beta_rom=8'd255; 8'd227:beta_rom=8'd255; 8'd228:beta_rom=8'd255; 8'd229:beta_rom=8'd255; 8'd230:beta_rom=8'd255; 8'd231:beta_rom=8'd255;
            8'd232:beta_rom=8'd255; 8'd233:beta_rom=8'd255; 8'd234:beta_rom=8'd255; 8'd235:beta_rom=8'd255; 8'd236:beta_rom=8'd255; 8'd237:beta_rom=8'd255; 8'd238:beta_rom=8'd255; 8'd239:beta_rom=8'd255;
            8'd240:beta_rom=8'd255; 8'd241:beta_rom=8'd255; 8'd242:beta_rom=8'd255; 8'd243:beta_rom=8'd255; 8'd244:beta_rom=8'd255; 8'd245:beta_rom=8'd255; 8'd246:beta_rom=8'd255; 8'd247:beta_rom=8'd255;
            8'd248:beta_rom=8'd255; 8'd249:beta_rom=8'd255; 8'd250:beta_rom=8'd255; 8'd251:beta_rom=8'd255; 8'd252:beta_rom=8'd255; 8'd253:beta_rom=8'd255; 8'd254:beta_rom=8'd255; 8'd255:beta_rom=8'd255;
            default: beta_rom = 8'd128;
        endcase
        default: beta_rom = 8'd128;
    endcase
end
endfunction

endmodule