// ============================================================
// TOP MODULE v9.0 — BB84 QKD with PC-Interactive Demo Mode
// ============================================================
//
// UPGRADE v9 (từ v8.1):
//   [1] UART RX: nhận Alice bits từ PC (bb84_fpga_demo.py)
//   [2] PC_INPUT mode (SW[9]=1): Alice data từ UART thay vì TRNG
//       → Flow: PC gửi bit → FPGA xử lý → kết quả gửi về PC
//   [3] Per-qubit response: gửi kết quả từng qubit về PC
//   [4] Batch mode: PC gửi chuỗi bit, FPGA xử lý tuần tự
//   [5] Giữ nguyên backward compatible: SW[9]=0 → hoạt động như v8.1
//
// DEMO FLOW (SW[9]=1, mode PC Input):
//   PC (Alice) → UART byte → FPGA decode → OOK TX → Channel →
//   OOK RX → Bob → Error Est → UART response → PC (Bob receives)
//
// UART COMMAND PROTOCOL (PC → FPGA):
//   Byte[7]=1: Qubit command
//     Bit[2] = alice_data
//     Bit[1] = alice_basis  (0=Z/Rectilinear, 1=X/Diagonal)
//     Bit[0] = bob_basis    (0=Z, 1=X)
//   Byte[7]=0: Control command
//     0x01 = Reset statistics
//     0x02 = Request status report (existing format)
//     0x10 = Echo test (FPGA replies 0xAA)
//
// UART RESPONSE (FPGA → PC, per qubit):
//   Header: '@'
//   Then 10 comma-separated decimal fields + '*\r\n'
//   @idx,a_data,a_basis,b_basis,bob_bit,bmatch,error,irrad,qber,sifted*\r\n
//
// FSM states: IDLE → WAIT_CMD → ENCODE → TX_WAIT → RX_WAIT →
//             PROCESS → REPORT → GAP → NEXT → IDLE
// ============================================================

module top_module (
    input  wire        CLOCK_50,
    input  wire [9:0]  SW,
    input  wire [3:0]  KEY,
    output wire [9:0]  LEDR,
    output wire [7:0]  LEDG,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire        UART_TXD,
    input  wire        UART_RXD,
    inout  wire [35:0] GPIO_0,
    inout  wire [35:0] GPIO_1
);

    // ============================
    // Control signals
    // ============================
    wire mode_auto       = ~SW[0];
    wire adaptive_enable = SW[1];
    wire turb_enable     = SW[4];
    wire [2:0] turb_level = SW[7:5];
    wire pc_input_mode   = SW[9];       // [v9] NEW: PC input mode
    wire spy_active      = ~KEY[0];
    wire manual_send     = ~KEY[1];
    wire clear_stats     = ~KEY[2];
    wire rst_n           = KEY[3];
    wire dynamic_turb    = turb_enable & (turb_level >= 3'd2);

    // ============================
    // GPIO
    // ============================
    wire gpio_tx_out;
    wire gpio_rx_in;
    assign GPIO_0[0]    = gpio_tx_out;
    assign gpio_rx_in   = ~GPIO_0[1];
    assign GPIO_0[35:2] = {34{1'bz}};
    assign GPIO_1       = {36{1'bz}};

    // ============================
    // Adaptive controller outputs
    // ============================
    wire [3:0]  adapt_power;
    wire [7:0]  adapt_basis_prob;
    wire [23:0] adapt_slot_width;
    wire [7:0]  adapt_rep_gap;
    wire [1:0]  adapt_mode;
    wire        adapt_tx_allowed;
    wire [7:0]  adapt_key_rate;

    localparam [23:0] FIXED_SLOT = 24'd250_000;   // 5ms per slot
	 localparam [23:0] TURBO_SLOT = 24'd500;   // 10µs thay vì 5ms

    wire [23:0] active_slot_width = pc_input_mode   ? TURBO_SLOT :
												adaptive_enable ? adapt_slot_width
																	 : FIXED_SLOT;
    wire [7:0]  active_basis_prob = adaptive_enable ? adapt_basis_prob : 8'd128;
    wire [3:0]  active_power      = adaptive_enable ? adapt_power : 4'd15;

    reg [23:0] slot_width_latched;

    // ============================
    // [v9] UART RX — Receive commands from PC
    // ============================
    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;
    wire       uart_rx_busy;

    uart_rx #(.CLK_FREQ(50000000), .BAUD(115200)) uart_rx_inst (
        .clk(CLOCK_50), .rst_n(rst_n),
        .rx_in(UART_RXD),
        .rx_data(uart_rx_data),
        .rx_valid(uart_rx_valid),
        .rx_busy(uart_rx_busy)
    );

    // [v9] PC command registers
    reg        pc_cmd_ready;     // New qubit command available
    reg        pc_cmd_data;      // Alice data bit from PC
    reg        pc_cmd_abasis;    // Alice basis from PC
    reg        pc_cmd_bbasis;    // Bob basis from PC
    reg        pc_reset_req;     // Reset request from PC
    reg        pc_status_req;    // Status request from PC

    // [v9] Command decoder
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            pc_cmd_ready  <= 1'b0;
            pc_cmd_data   <= 1'b0;
            pc_cmd_abasis <= 1'b0;
            pc_cmd_bbasis <= 1'b0;
            pc_reset_req  <= 1'b0;
            pc_status_req <= 1'b0;
        end else begin
            // Clear one-shot signals
            if (pc_cmd_ready && fsm == FSM_ENCODE)
                pc_cmd_ready <= 1'b0;
            pc_reset_req  <= 1'b0;
            pc_status_req <= 1'b0;

            if (uart_rx_valid && pc_input_mode) begin
                if (uart_rx_data[7]) begin
                    // Qubit command: bit[7]=1
                    pc_cmd_ready  <= 1'b1;
                    pc_cmd_data   <= uart_rx_data[2];
                    pc_cmd_abasis <= uart_rx_data[1];
                    pc_cmd_bbasis <= uart_rx_data[0];
                end else begin
                    // Control command: bit[7]=0
                    case (uart_rx_data)
                        8'h01: pc_reset_req  <= 1'b1;
                        8'h02: pc_status_req <= 1'b1;
                        default: ;
                    endcase
                end
            end
        end
    end

    // ============================
    // TRNG
    // ============================
    wire rand_a_data, rand_a_basis, rand_b_basis;
    wire [7:0] rand_a_byte, rand_b_byte;
    wire trng_advance;

    trng_random #(.SEED(16'h0000)) gen_alice_data (
        .clk(CLOCK_50), .rst_n(rst_n), .enable(trng_advance),
        .random_bit(rand_a_data), .random_byte()
    );
    trng_random #(.SEED(16'h0000)) gen_alice_basis (
        .clk(CLOCK_50), .rst_n(rst_n), .enable(trng_advance),
        .random_bit(rand_a_basis), .random_byte(rand_a_byte)
    );
    trng_random #(.SEED(16'h0000)) gen_bob_basis (
        .clk(CLOCK_50), .rst_n(rst_n), .enable(trng_advance),
        .random_bit(rand_b_basis), .random_byte(rand_b_byte)
    );

    wire alice_basis_biased = (rand_a_byte < active_basis_prob) ? 1'b0 : 1'b1;
    wire bob_basis_biased   = (rand_b_byte < active_basis_prob) ? 1'b0 : 1'b1;

    // [v9] MUX: data source depends on mode
    //   pc_input_mode=1 → PC provides alice data/basis/bob_basis
    //   pc_input_mode=0 → original behavior (TRNG or switches)
    wire a_data_src  = pc_input_mode ? pc_cmd_data   :
                       mode_auto     ? rand_a_data    : SW[2];
    wire a_basis_src = pc_input_mode ? pc_cmd_abasis  :
                       mode_auto     ? alice_basis_biased : SW[3];
    wire b_basis_src = pc_input_mode ? pc_cmd_bbasis  :
                       mode_auto     ? bob_basis_biased   : SW[8];

    // Wires used by rest of design
    wire a_data  = a_data_src;
    wire a_basis = a_basis_src;
    wire b_basis = b_basis_src;

    // ============================
    // Alice
    // ============================
    wire [1:0] tx_qubit;
    alice alice_inst (.a(a_data), .b(a_basis), .qubit(tx_qubit));

    // ============================
    // OOK TX
    // ============================
    wire tx_serial, tx_frame_done, tx_active;
    reg  tx_start;

    ook_tx_serializer tx_inst (
        .clk(CLOCK_50), .rst_n(rst_n),
        .tx_start(tx_start), .qubit_in(tx_qubit),
        .slot_width(slot_width_latched),
        .serial_out(tx_serial),
        .frame_done(tx_frame_done),
        .tx_active(tx_active)
    );

    wire tx_powered;
    pwm_power pwm_inst (
        .clk(CLOCK_50), .rst_n(rst_n),
        .power_level(active_power),
        .signal_in(tx_serial), .signal_out(tx_powered)
    );
    assign gpio_tx_out = tx_powered;

    // ============================
    // Channel: Gamma-Gamma
    // ============================
    wire channel_in = pc_input_mode ? tx_serial :    // [v9] PC mode: always internal
                      SW[9]        ? gpio_rx_in :    // laser mode in non-PC
                                     tx_serial;

    wire turb_out;
    wire [2:0] turb_cur_level;
    wire turb_fade, turb_scint;
    wire [7:0] turb_flip_cnt, turb_fade_cnt;
    wire [7:0] irrad_x, irrad_y, irrad_combined;
    wire ch_sample_en;

    gamma_gamma_channel turb_inst (
        .clk(CLOCK_50), .rst_n(rst_n),
        .signal_in(channel_in), .signal_out(turb_out),
        .turb_enable(turb_enable), .turb_level(turb_level),
        .dynamic_enable(dynamic_turb),
        .sample_en(ch_sample_en),
        .current_level(turb_cur_level),
        .fade_active(turb_fade), .scint_active(turb_scint),
        .flip_count(turb_flip_cnt), .fade_count(turb_fade_cnt),
        .irradiance_x(irrad_x),
        .irradiance_y(irrad_y),
        .irradiance_combined(irrad_combined)
    );

    // ============================
    // OOK RX
    // ============================
    wire [1:0] rx_qubit;
    wire rx_valid_pulse, rx_active_w, sig_detect;
    reg  rx_valid_flag;

    ook_rx_deserializer rx_inst (
        .clk(CLOCK_50), .rst_n(rst_n),
        .serial_in(turb_out),
        .slot_width(slot_width_latched),
        .qubit_out(rx_qubit),
        .qubit_valid(rx_valid_pulse),
        .rx_active(rx_active_w),
        .signal_detect(sig_detect)
    );

    // ============================
    // Bob + Error estimation
    // ============================
    wire bob_decoded;
    bob bob_inst (
        .qubit(rx_qubit), .b_prime(b_basis),
        .spy_control(spy_active), .a1(bob_decoded)
    );

    wire match_w, basis_match_w, spy_detect_w;
    reg a_data_latch, a_basis_latch;

    error_estimation err_inst (
        .a(a_data_latch), .a1(bob_decoded),
        .b(a_basis_latch), .b_prime(b_basis),
        .match(match_w), .basis_match(basis_match_w),
        .spy_detect(spy_detect_w)
    );

    // ============================
    // Channel Monitor
    // ============================
    wire [7:0] mon_qber, mon_snr, mon_photon, mon_sifted;
    wire       mon_window;
    reg        evt_done, evt_lost, evt_bmatch, evt_derr;

    channel_monitor ch_mon (
        .clk(CLOCK_50), .rst_n(rst_n),
        .evt_qubit_done(evt_done),
        .evt_qubit_lost(evt_lost),
        .evt_basis_match(evt_bmatch),
        .evt_data_error(evt_derr),
        .signal_detect(sig_detect),
        .enable(1'b1), .clear(clear_stats | pc_reset_req),
        .qber(mon_qber), .snr_level(mon_snr),
        .photon_rate(mon_photon), .sifted_rate(mon_sifted),
        .window_pulse(mon_window)
    );

    // ============================
    // Adaptive Controller
    // ============================
    adaptive_controller adapt_ctrl (
        .clk(CLOCK_50), .rst_n(rst_n),
        .qber(mon_qber), .snr_level(mon_snr),
        .photon_rate(mon_photon), .window_pulse(mon_window),
        .adaptive_enable(adaptive_enable),
        .manual_power(4'd15),
        .manual_basis_prob(8'd128),
        .manual_slot_width(FIXED_SLOT),
        .power_level(adapt_power),
        .basis_prob_z(adapt_basis_prob),
        .slot_width_out(adapt_slot_width),
        .rep_gap(adapt_rep_gap),
        .mode(adapt_mode),
        .tx_allowed(adapt_tx_allowed),
        .key_rate_est(adapt_key_rate)
    );

    // ============================
    // UART TX (shared between reporter and per-qubit response)
    // ============================
    wire [7:0] uart_data_w;
    wire       uart_start_w, uart_busy_w;

    uart_tx uart_inst (
        .clk(CLOCK_50), .rst_n(rst_n),
        .tx_data(uart_data_w),
        .tx_start(uart_start_w),
        .tx_out(UART_TXD),
        .tx_busy(uart_busy_w)
    );

    // ============================
    // [v9] Per-Qubit Response Reporter
    // ============================
    reg [15:0] total_cnt, sifted_cnt, error_cnt, key_cnt;

    // Per-qubit result registers (latched in FSM_PROCESS)
    reg        result_ready;
    reg        res_a_data, res_a_basis, res_b_basis;
    reg        res_bob_bit, res_bmatch, res_error;
    reg [7:0]  res_irrad;

    // [v9] Dual-source UART multiplexer:
    //   - Per-qubit reporter (priority when result_ready)
    //   - Status reporter (existing uart_reporter)
    wire [7:0] rpt_uart_data;
    wire       rpt_uart_start;
    wire [7:0] stat_uart_data;
    wire       stat_uart_start;

    // Per-qubit response reporter instance
    per_qubit_reporter pq_rpt (
        .clk(CLOCK_50), .rst_n(rst_n),
        .result_ready(result_ready & pc_input_mode),
        .a_data(res_a_data), .a_basis(res_a_basis), .b_basis(res_b_basis),
        .bob_bit(res_bob_bit), .basis_match(res_bmatch), .data_error(res_error),
        .irradiance(res_irrad),
        .total_qubits(total_cnt), .total_sifted(sifted_cnt), .total_errors(error_cnt),
        .uart_data(rpt_uart_data),
        .uart_start(rpt_uart_start),
        .uart_busy(uart_busy_w),
        .report_done()
    );

    // Status reporter (existing)
    uart_reporter logger_inst (
        .clk(CLOCK_50), .rst_n(rst_n),
        .qber(mon_qber), .snr_level(mon_snr),
        .photon_rate(mon_photon), .sifted_rate(mon_sifted),
        .power_level(active_power),
        .basis_prob(active_basis_prob),
        .slot_width(slot_width_latched),
        .rep_gap(adapt_rep_gap),
        .adapt_mode(adapt_mode),
        .turb_level(turb_level),
        .fade_active(turb_fade),
        .irradiance(irrad_combined),
        .total_qubits(total_cnt),
        .total_sifted(sifted_cnt),
        .total_errors(error_cnt),
        .window_pulse(mon_window | pc_status_req),
        .enable(~pc_input_mode),  // [v9] disable auto-reporting in PC mode, at first dont have pc_status_req
        .uart_data(stat_uart_data),
        .uart_start(stat_uart_start),
        .uart_busy(uart_busy_w)
    );

    // UART MUX: per-qubit reporter takes priority in PC mode
    assign uart_data_w  = (pc_input_mode && rpt_uart_start) ? rpt_uart_data  : stat_uart_data;
    assign uart_start_w = (pc_input_mode && rpt_uart_start) ? rpt_uart_start : stat_uart_start;

    // ============================
    // Main FSM — BB84 Protocol (v9: extended with WAIT_CMD & REPORT)
    // ============================
    localparam FSM_IDLE     = 4'd0;
    localparam FSM_WAIT_CMD = 4'd1;   // [v9] Wait for PC command
    localparam FSM_ENCODE   = 4'd2;
    localparam FSM_TX_WAIT  = 4'd3;
    localparam FSM_RX_WAIT  = 4'd4;
    localparam FSM_PROCESS  = 4'd5;
    localparam FSM_REPORT   = 4'd6;   // [v9] Send per-qubit result
    localparam FSM_GAP      = 4'd7;
    localparam FSM_NEXT     = 4'd8;

    reg [3:0]  fsm;
    reg [26:0] timeout_cnt, gap_cnt;
    reg [3:0]  key_shift;
    reg        last_error;

    wire [26:0] rx_timeout = {slot_width_latched[22:0], 4'b0000};
    wire [24:0] base_gap   = {slot_width_latched[23:0], 1'b0};
    wire [7:0]  eff_gap    = adaptive_enable ? adapt_rep_gap : 8'd1;
    wire [26:0] gap_total  = (eff_gap <= 8'd1) ? {2'b00, base_gap} :
                             (eff_gap <= 8'd2) ? {1'b0, base_gap, 1'b0} :
                             (eff_gap <= 8'd4) ? {base_gap, 2'b00} :
                             (eff_gap <= 8'd8) ? {base_gap[23:0], 3'b000} :
                                                  {base_gap[22:0], 4'b0000};

    wire tx_permitted = adaptive_enable ? adapt_tx_allowed : 1'b1;

    reg key1_prev;
    wire key1_pulse = manual_send & ~key1_prev;

    assign ch_sample_en = (fsm == FSM_ENCODE);

    // [v9] Report timing counter
    reg [19:0] report_wait_cnt;

    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            fsm              <= FSM_IDLE;
            tx_start         <= 1'b0;
            a_data_latch     <= 1'b0;
            a_basis_latch    <= 1'b0;
            total_cnt        <= 16'd0;
            sifted_cnt       <= 16'd0;
            error_cnt        <= 16'd0;
            key_cnt          <= 16'd0;
            key_shift        <= 4'd0;
            timeout_cnt      <= 27'd0;
            gap_cnt          <= 27'd0;
            last_error       <= 1'b0;
            key1_prev        <= 1'b0;
            rx_valid_flag    <= 1'b0;
            slot_width_latched <= FIXED_SLOT;
            evt_done         <= 1'b0;
            evt_lost         <= 1'b0;
            evt_bmatch       <= 1'b0;
            evt_derr         <= 1'b0;
            result_ready     <= 1'b0;
            res_a_data       <= 1'b0;
            res_a_basis      <= 1'b0;
            res_b_basis      <= 1'b0;
            res_bob_bit      <= 1'b0;
            res_bmatch       <= 1'b0;
            res_error        <= 1'b0;
            res_irrad        <= 8'd128;
            report_wait_cnt  <= 20'd0;
        end else begin
            key1_prev <= manual_send;

            evt_done   <= 1'b0;
            evt_lost   <= 1'b0;
            evt_bmatch <= 1'b0;
            evt_derr   <= 1'b0;

            if (rx_valid_pulse && (fsm == FSM_TX_WAIT || fsm == FSM_RX_WAIT))
                rx_valid_flag <= 1'b1;

            if (clear_stats || pc_reset_req) begin
                total_cnt  <= 16'd0;
                sifted_cnt <= 16'd0;
                error_cnt  <= 16'd0;
                key_cnt    <= 16'd0;
                key_shift  <= 4'd0;
                last_error <= 1'b0;
            end

            case (fsm)
                FSM_IDLE: begin
                    tx_start      <= 1'b0;
                    rx_valid_flag <= 1'b0;
                    result_ready  <= 1'b0;

                    if (pc_input_mode) begin
                        // [v9] PC mode: go to WAIT_CMD
                        fsm <= FSM_WAIT_CMD;
                    end else if (tx_permitted && (mode_auto || key1_pulse)) begin
                        // Original mode: auto or manual trigger
                        slot_width_latched <= active_slot_width;
                        fsm <= FSM_ENCODE;
                    end
                end

                FSM_WAIT_CMD: begin
                    // [v9] Wait for PC to send a qubit command
                    tx_start      <= 1'b0;
                    rx_valid_flag <= 1'b0;
                    result_ready  <= 1'b0;

                    if (!pc_input_mode) begin
                        fsm <= FSM_IDLE;  // Mode changed, go back
                    end else if (pc_cmd_ready) begin
                        slot_width_latched <= active_slot_width;
                        fsm <= FSM_ENCODE;
                    end
                end

                FSM_ENCODE: begin
                    a_data_latch  <= a_data;
                    a_basis_latch <= a_basis;
                    rx_valid_flag <= 1'b0;
                    tx_start      <= 1'b1;
                    fsm           <= FSM_TX_WAIT;
                end

                FSM_TX_WAIT: begin
                    tx_start <= 1'b0;
                    if (tx_frame_done) begin
                        fsm         <= FSM_RX_WAIT;
                        timeout_cnt <= 27'd0;
                    end
                end

                FSM_RX_WAIT: begin
                    timeout_cnt <= timeout_cnt + 27'd1;
                    if (rx_valid_flag)
                        fsm <= FSM_PROCESS;
                    else if (timeout_cnt >= rx_timeout) begin
                        evt_lost <= 1'b1;
                        fsm      <= FSM_GAP;
                        gap_cnt  <= 27'd0;
                    end
                end

                FSM_PROCESS: begin
                    rx_valid_flag <= 1'b0;
                    total_cnt     <= total_cnt + 16'd1;
                    evt_done      <= 1'b1;

                    // [v9] Latch per-qubit results
                    res_a_data  <= a_data_latch;
                    res_a_basis <= a_basis_latch;
                    res_b_basis <= b_basis;
                    res_bob_bit <= bob_decoded;
                    res_bmatch  <= basis_match_w;
                    res_irrad   <= irrad_combined;

                    if (basis_match_w) begin
                        sifted_cnt <= sifted_cnt + 16'd1;
                        evt_bmatch <= 1'b1;
                        if (spy_detect_w) begin
                            error_cnt  <= error_cnt + 16'd1;
                            evt_derr   <= 1'b1;
                            last_error <= 1'b1;
                            res_error  <= 1'b1;
                        end else begin
                            key_cnt    <= key_cnt + 16'd1;
                            key_shift  <= {key_shift[2:0], bob_decoded};
                            last_error <= 1'b0;
                            res_error  <= 1'b0;
                        end
                    end else begin
                        last_error <= 1'b0;
                        res_error  <= 1'b0;
                    end

                    // [v9] Go to REPORT state in PC mode, else GAP
                    if (pc_input_mode) begin
                        result_ready    <= 1'b1;
                        report_wait_cnt <= 20'd0;
                        fsm             <= FSM_REPORT;
                    end else begin
                        fsm     <= FSM_GAP;
                        gap_cnt <= 27'd0;
                    end
                end

                FSM_REPORT: begin
                    // [v9] Wait for per-qubit response to finish sending
                    report_wait_cnt <= report_wait_cnt + 1'b1;
                    // Give reporter time to complete (~500us = 25000 cycles)
                    if (report_wait_cnt >= 20'd200_000) begin
                        result_ready <= 1'b0;
                        fsm          <= FSM_GAP;
                        gap_cnt      <= 27'd0;
                    end
                end

                FSM_GAP: begin
                    rx_valid_flag <= 1'b0;
                    result_ready  <= 1'b0;
                    gap_cnt       <= gap_cnt + 27'd1;

                    // [v9] In PC mode, use shorter gap
                    if (pc_input_mode) begin
                        if (gap_cnt >= {3'b000, slot_width_latched})
                            fsm <= FSM_NEXT;
                    end else begin
                        if (gap_cnt >= gap_total)
                            fsm <= FSM_NEXT;
                    end
                end

                FSM_NEXT: begin
                    rx_valid_flag <= 1'b0;
                    result_ready  <= 1'b0;
                    fsm           <= FSM_IDLE;
                end

                default: fsm <= FSM_IDLE;
            endcase
        end
    end

    assign trng_advance = (fsm == FSM_NEXT);

    // ============================
    // LEDs
    // ============================
    assign LEDR[1:0] = tx_qubit;
    assign LEDR[3:2] = rx_qubit;
    assign LEDR[4]   = tx_active;
    assign LEDR[5]   = rx_active_w;
    assign LEDR[6]   = sig_detect;
    assign LEDR[7]   = basis_match_w;
    assign LEDR[8]   = spy_active;
    assign LEDR[9]   = pc_input_mode;   // [v9] Show PC mode

    assign LEDG[1:0] = adapt_mode;
    assign LEDG[2]   = adapt_tx_allowed;
    assign LEDG[3]   = turb_enable;
    assign LEDG[4]   = turb_fade;
    assign LEDG[5]   = turb_scint;
    assign LEDG[6]   = adaptive_enable;
    assign LEDG[7]   = pc_cmd_ready;    // [v9] Show pending PC cmd

    // ============================
    // 7-Segment Displays
    // ============================
    seven_seg_decoder h0 (.hex_digit(total_cnt[3:0]), .segments(HEX0));

    wire [3:0] qber_disp = (mon_qber >= 8'd100) ? 4'hF :
                           (mon_qber >= 8'd50)  ? 4'hA :
                           (mon_qber >= 8'd25)  ? 4'h6 :
                           (mon_qber >= 8'd12)  ? 4'h3 :
                           (mon_qber >= 8'd4)   ? 4'h1 : 4'h0;
    seven_seg_decoder h1 (.hex_digit(qber_disp), .segments(HEX1));
    seven_seg_decoder h2 (.hex_digit(mon_snr[7:4]), .segments(HEX2));
    seven_seg_decoder h3 (.hex_digit(fsm[3:0]), .segments(HEX3)); // [v9] Show FSM state

endmodule

// ============================================================
// PER-QUBIT REPORTER — Sends result of each qubit to PC
// ============================================================
// Format: @<a_data>,<a_basis>,<b_basis>,<bob>,<bmatch>,<err>,<irrad>,<total>,<sifted>,<errors>*\r\n
// Example: @1,0,0,1,1,0,135,0042,0021,0003*\r\n
// ============================================================
module per_qubit_reporter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        result_ready,    // Pulse: new qubit result
    input  wire        a_data,
    input  wire        a_basis,
    input  wire        b_basis,
    input  wire        bob_bit,
    input  wire        basis_match,
    input  wire        data_error,
    input  wire [7:0]  irradiance,
    input  wire [15:0] total_qubits,
    input  wire [15:0] total_sifted,
    input  wire [15:0] total_errors,
    output reg  [7:0]  uart_data,
    output reg         uart_start,
    input  wire        uart_busy,
    output reg         report_done
);

    reg [7:0]  msg_buf [0:49];
    reg [5:0]  msg_len;
    reg [5:0]  send_idx;

    localparam S_IDLE  = 2'd0;
    localparam S_BUILD = 2'd1;
    localparam S_SEND  = 2'd2;
    localparam S_WAIT  = 2'd3;

    reg [1:0] state;
    reg       result_latched;

    // Latch result on rising edge of result_ready
    reg prev_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            uart_start    <= 1'b0;
            uart_data     <= 8'd0;
            send_idx      <= 6'd0;
            msg_len       <= 6'd0;
            report_done   <= 1'b0;
            prev_ready    <= 1'b0;
        end else begin
            uart_start  <= 1'b0;
            report_done <= 1'b0;
            prev_ready  <= result_ready;

            case (state)
                S_IDLE: begin
                    if (result_ready && !prev_ready)
                        state <= S_BUILD;
                end

                S_BUILD: begin
                    // Build response message
                    msg_buf[0]  <= "@";
                    msg_buf[1]  <= a_data ? "1" : "0";
                    msg_buf[2]  <= ",";
                    msg_buf[3]  <= a_basis ? "1" : "0";
                    msg_buf[4]  <= ",";
                    msg_buf[5]  <= b_basis ? "1" : "0";
                    msg_buf[6]  <= ",";
                    msg_buf[7]  <= bob_bit ? "1" : "0";
                    msg_buf[8]  <= ",";
                    msg_buf[9]  <= basis_match ? "1" : "0";
                    msg_buf[10] <= ",";
                    msg_buf[11] <= data_error ? "1" : "0";
                    msg_buf[12] <= ",";
                    // Irradiance (3 decimal digits)
                    msg_buf[13] <= dec_digit(irradiance / 100);
                    msg_buf[14] <= dec_digit((irradiance / 10) % 10);
                    msg_buf[15] <= dec_digit(irradiance % 10);
                    msg_buf[16] <= ",";
                    // Total qubits (4 hex)
                    msg_buf[17] <= hex_char(total_qubits[15:12]);
                    msg_buf[18] <= hex_char(total_qubits[11:8]);
                    msg_buf[19] <= hex_char(total_qubits[7:4]);
                    msg_buf[20] <= hex_char(total_qubits[3:0]);
                    msg_buf[21] <= ",";
                    // Total sifted (4 hex)
                    msg_buf[22] <= hex_char(total_sifted[15:12]);
                    msg_buf[23] <= hex_char(total_sifted[11:8]);
                    msg_buf[24] <= hex_char(total_sifted[7:4]);
                    msg_buf[25] <= hex_char(total_sifted[3:0]);
                    msg_buf[26] <= ",";
                    // Total errors (4 hex)
                    msg_buf[27] <= hex_char(total_errors[15:12]);
                    msg_buf[28] <= hex_char(total_errors[11:8]);
                    msg_buf[29] <= hex_char(total_errors[7:4]);
                    msg_buf[30] <= hex_char(total_errors[3:0]);
                    // Terminator
                    msg_buf[31] <= "*";
                    msg_buf[32] <= "\r";
                    msg_buf[33] <= "\n";

                    msg_len  <= 6'd34;
                    send_idx <= 6'd0;
                    state    <= S_SEND;
                end

                S_SEND: begin
                    if (send_idx >= msg_len) begin
                        report_done <= 1'b1;
                        state       <= S_IDLE;
                    end else if (!uart_busy) begin
                        uart_data  <= msg_buf[send_idx];
                        uart_start <= 1'b1;
                        send_idx   <= send_idx + 1'b1;
                        state      <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (uart_busy)
                        state <= S_SEND;
                end
            endcase
        end
    end

    function [7:0] dec_digit;
        input [7:0] val;
    begin
        if (val <= 8'd9) dec_digit = "0" + val;
        else             dec_digit = "0";
    end
    endfunction

    function [7:0] hex_char;
        input [3:0] nib;
    begin
        if (nib <= 4'd9) hex_char = "0" + {4'd0, nib};
        else             hex_char = "A" + {4'd0, nib - 4'd10};
    end
    endfunction

endmodule

// ============================================================
module seven_seg_decoder (
    input  wire [3:0] hex_digit,
    output reg  [6:0] segments
);
    always @(*) begin
        case (hex_digit)
            4'h0: segments = 7'b1000000; 4'h1: segments = 7'b1111001;
            4'h2: segments = 7'b0100100; 4'h3: segments = 7'b0110000;
            4'h4: segments = 7'b0011001; 4'h5: segments = 7'b0010010;
            4'h6: segments = 7'b0000010; 4'h7: segments = 7'b1111000;
            4'h8: segments = 7'b0000000; 4'h9: segments = 7'b0010000;
            4'hA: segments = 7'b0001000; 4'hB: segments = 7'b0000011;
            4'hC: segments = 7'b1000110; 4'hD: segments = 7'b0100001;
            4'hE: segments = 7'b0000110; 4'hF: segments = 7'b0001110;
            default: segments = 7'b1111111;
        endcase
    end
endmodule