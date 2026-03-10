// ============================================================
// OOK RX DESERIALIZER (v2 - fixed counter overflow)
// ============================================================
// BUG FIX: wait_cnt expanded from 24-bit to 26-bit
//   Before: 24-bit max = 16,777,215
//   1.5 x slot_width = 1.5 x 12,500,000 = 18,750,000 -> OVERFLOW!
//   2.0 x slot_width = 2.0 x 12,500,000 = 25,000,000 -> OVERFLOW!
//   After: 26-bit max = 67,108,863 -> safe for all valid slot_width
//
// Frame: [SYNC=1][B1][B0][IDLE=0], each slot = slot_width cycles
// 1. Detect rising edge -> SYNC
// 2. Wait 1.5 slots -> sample qubit[1] at middle of slot 1
// 3. Wait 1.0 slot  -> sample qubit[0] at middle of slot 2
// 4. Output qubit + valid pulse
// ============================================================
module ook_rx_deserializer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        serial_in,
    input  wire [23:0] slot_width,
    output reg  [1:0]  qubit_out,
    output reg         qubit_valid,
    output reg         rx_active,
    output reg         signal_detect
);

    // ========================
    // Debounce (8 cycles stable)
    // ========================
    reg [3:0] db_cnt;
    reg       db_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            db_cnt <= 4'd0;
            db_in  <= 1'b0;
        end else begin
            if (serial_in != db_in) begin
                if (db_cnt >= 4'd8) begin
                    db_in  <= serial_in;
                    db_cnt <= 4'd0;
                end else
                    db_cnt <= db_cnt + 1'b1;
            end else
                db_cnt <= 4'd0;
        end
    end

    // ========================
    // Rising edge detect
    // ========================
    reg db_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) db_prev <= 1'b0;
        else        db_prev <= db_in;
    end
    wire rising = db_in & ~db_prev;

    // ========================
    // Signal presence (timeout = 8 x slot_width)
    // ========================
    reg [26:0] no_sig_timer;
    wire [26:0] sig_timeout = {slot_width, 3'b000};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            no_sig_timer  <= 27'd0;
            signal_detect <= 1'b0;
        end else begin
            if (db_in) begin
                no_sig_timer  <= 27'd0;
                signal_detect <= 1'b1;
            end else begin
                if (no_sig_timer < sig_timeout)
                    no_sig_timer <= no_sig_timer + 1'b1;
                else
                    signal_detect <= 1'b0;
            end
        end
    end

    // ========================
    // Frame receiver FSM
    // ========================
    localparam ST_IDLE    = 3'd0;
    localparam ST_WAIT_B1 = 3'd1;
    localparam ST_SAMP_B1 = 3'd2;
    localparam ST_WAIT_B0 = 3'd3;
    localparam ST_SAMP_B0 = 3'd4;
    localparam ST_DONE    = 3'd5;

    reg [2:0]  state;
    reg [25:0] wait_cnt;                                       // 26-bit (was 24)
    wire [24:0] half_slot = {1'b0, slot_width[23:1]};          // slot/2, 25-bit

    // Pre-compute thresholds with full width (no overflow)
    wire [25:0] thresh_b1   = {2'b00, slot_width} + {1'b0, half_slot} - 26'd1;
    wire [25:0] thresh_b0   = {2'b00, slot_width} - 26'd1;
    wire [25:0] thresh_done = {1'b0, slot_width, 1'b0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            qubit_out   <= 2'd0;
            qubit_valid <= 1'b0;
            rx_active   <= 1'b0;
            wait_cnt    <= 26'd0;
        end else begin
            qubit_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    rx_active <= 1'b0;
                    if (rising) begin
                        wait_cnt  <= 26'd0;
                        rx_active <= 1'b1;
                        state     <= ST_WAIT_B1;
                    end
                end

                ST_WAIT_B1: begin
                    if (wait_cnt >= thresh_b1)
                        state <= ST_SAMP_B1;
                    else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                ST_SAMP_B1: begin
                    qubit_out[1] <= db_in;
                    wait_cnt     <= 26'd0;
                    state        <= ST_WAIT_B0;
                end

                ST_WAIT_B0: begin
                    if (wait_cnt >= thresh_b0)
                        state <= ST_SAMP_B0;
                    else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                ST_SAMP_B0: begin
                    qubit_out[0] <= db_in;
                    qubit_valid  <= 1'b1;
                    wait_cnt     <= 26'd0;
                    state        <= ST_DONE;
                end

                ST_DONE: begin
                    if (wait_cnt >= thresh_done) begin
                        state     <= ST_IDLE;
                        rx_active <= 1'b0;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule