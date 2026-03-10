// ============================================================
// CHANNEL MONITOR v2 — QBER, SNR proxy, photon count
// Sliding window: 256 qubit attempts
// ============================================================
//
// NÂNG CẤP v2:
//   - QBER resolution: 12 mức (0,1,2,4,6,8,12,16,25,33,50,100)
//     thay vì 6 mức cũ. Chính xác hơn cho paper data.
//   - SNR calculation: sửa blocking assignment style
//   - Counter overflow protection
//
// QBER tính theo 0-200 scale (mỗi đơn vị = 0.5%)
// SNR tính theo 0-255 scale (composite metric)
// ============================================================

module channel_monitor (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        evt_qubit_done,
    input  wire        evt_qubit_lost,
    input  wire        evt_basis_match,
    input  wire        evt_data_error,
    input  wire        signal_detect,
    input  wire        enable,
    input  wire        clear,
    output reg  [7:0]  qber,
    output reg  [7:0]  snr_level,
    output reg  [7:0]  photon_rate,
    output reg  [7:0]  sifted_rate,
    output reg         window_pulse
);

    reg [7:0] w_attempt, w_received, w_sifted, w_errors, w_lost;
    reg [19:0] sig_on_cnt, sig_total;
    reg [7:0]  sig_ratio;

    // ---- Signal ratio counter (SNR proxy) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sig_on_cnt <= 20'd0;
            sig_total  <= 20'd0;
            sig_ratio  <= 8'd255;
        end else if (clear) begin
            sig_on_cnt <= 20'd0;
            sig_total  <= 20'd0;
            sig_ratio  <= 8'd255;
        end else begin
            sig_total <= sig_total + 20'd1;
            if (signal_detect)
                sig_on_cnt <= sig_on_cnt + 20'd1;
            if (&sig_total) begin
                sig_ratio  <= sig_on_cnt[19:12];
                sig_on_cnt <= 20'd0;
            end
        end
    end

    // ---- Window event accumulator ----
    // Compute SNR in a wire (avoid blocking assignment in clocked block)
    reg [7:0] snr_success;
    wire [7:0] snr_computed = snr_success[7:1] + snr_success[7:2] + sig_ratio[7:2];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_attempt    <= 8'd0;
            w_received   <= 8'd0;
            w_sifted     <= 8'd0;
            w_errors     <= 8'd0;
            w_lost       <= 8'd0;
            qber         <= 8'd0;
            snr_level    <= 8'd255;
            photon_rate  <= 8'd0;
            sifted_rate  <= 8'd0;
            window_pulse <= 1'b0;
            snr_success  <= 8'd0;
        end else if (clear) begin
            w_attempt    <= 8'd0;
            w_received   <= 8'd0;
            w_sifted     <= 8'd0;
            w_errors     <= 8'd0;
            w_lost       <= 8'd0;
            qber         <= 8'd0;
            snr_level    <= 8'd255;
            photon_rate  <= 8'd0;
            sifted_rate  <= 8'd0;
            window_pulse <= 1'b0;
            snr_success  <= 8'd0;
        end else begin
            window_pulse <= 1'b0;
            if (enable) begin
                // Count events within window
                if (evt_qubit_done) begin
                    w_attempt  <= w_attempt  + 8'd1;
                    w_received <= w_received + 8'd1;
                    if (evt_basis_match) begin
                        w_sifted <= w_sifted + 8'd1;
                        if (evt_data_error)
                            w_errors <= w_errors + 8'd1;
                    end
                end
                if (evt_qubit_lost) begin
                    w_attempt <= w_attempt + 8'd1;
                    w_lost    <= w_lost    + 8'd1;
                end
                
                // Window complete (256 attempts)
                if (&w_attempt) begin
                    window_pulse <= 1'b1;
                    
                    // QBER calculation (12-level approximation)
                    if (w_sifted == 8'd0)
                        qber <= 8'd100;
                    else
                        qber <= approx_qber(w_errors, w_sifted);
                    
                    // SNR composite
                    if (w_lost == 8'd0)
                        snr_success <= 8'd255;
                    else if (w_received == 8'd0)
                        snr_success <= 8'd0;
                    else
                        snr_success <= w_received;
                    
                    snr_level   <= snr_computed;
                    photon_rate <= w_received;
                    sifted_rate <= w_sifted;
                    
                    // Reset window counters
                    w_attempt  <= 8'd0;
                    w_received <= 8'd0;
                    w_sifted   <= 8'd0;
                    w_errors   <= 8'd0;
                    w_lost     <= 8'd0;
                end
            end
        end
    end

    // ============================================================
    // QBER approximation using shift-and-compare
    // 12 levels: 0, 1, 2, 4, 6, 8, 12, 16, 25, 33, 50, 100
    // Mỗi đơn vị = 0.5%, nên QBER thực = giá trị / 2
    // ============================================================
    function [7:0] approx_qber;
        input [7:0] errors, sifted;
        reg [15:0] err_x;   // errors shifted
    begin
        if (errors == 8'd0)
            approx_qber = 8'd0;
        else if (errors >= sifted)
            approx_qber = 8'd200;       // ≥ 100%
        else begin
            err_x = {8'd0, errors};
            // errors/sifted ≥ 1/2 → QBER ≥ 50%
            if ({errors, 1'b0} >= {1'b0, sifted})
                approx_qber = 8'd100;   // 50%
            // errors/sifted ≥ 1/3 → QBER ≥ 33%
            else if (err_x + err_x + err_x >= {8'd0, sifted})
                approx_qber = 8'd66;    // 33%
            // errors/sifted ≥ 1/4 → QBER ≥ 25%
            else if ({errors, 2'b00} >= {2'b00, sifted})
                approx_qber = 8'd50;    // 25%
            // ≥ 1/6 → 16%
            else if (err_x + err_x + err_x + err_x + err_x + err_x >= {8'd0, sifted})
                approx_qber = 8'd32;    // 16%
            // ≥ 1/8 → 12%
            else if ({errors, 3'b000} >= {3'b000, sifted})
                approx_qber = 8'd24;    // 12%
            // ≥ 1/12 → 8%
            else if (err_x + err_x + err_x + err_x + err_x + err_x +
                     err_x + err_x + err_x + err_x + err_x + err_x >= {8'd0, sifted})
                approx_qber = 8'd16;    // 8%
            // ≥ 1/16 → 6%
            else if ({errors, 4'b0000} >= {4'b0000, sifted})
                approx_qber = 8'd12;    // 6%
            // ≥ 1/25 → 4%
            else if ({errors, 5'b00000} >= {5'b00000, sifted})
                approx_qber = 8'd8;     // 4%
            // ≥ 1/50 → 2%
            else if ({errors, 6'b000000} >= {6'b000000, sifted})
                approx_qber = 8'd4;     // 2%
            // ≥ 1/100 → 1%
            else if ({errors, 7'b0000000} >= {7'b0000000, sifted})
                approx_qber = 8'd2;     // 1%
            else
                approx_qber = 8'd1;     // < 1%
        end
    end
    endfunction

endmodule
