// ============================================================
// UART DATA REPORTER v2 — With Gamma-Gamma Irradiance
// ============================================================
//
// PACKET FORMAT:
//   $QBER,SNR,PHOT,SIFT,PWR,BPROB,SLOT,GAP,MODE,TURB,FADE,IRRAD,TOT,TSFT,TERR*\r\n
//
// NEW: IRRAD field = combined Gamma-Gamma irradiance (000-255)
//      128 = mean irradiance (I/I0 = 1.0)
//      < 30 = deep fade zone
//
// Example:
//   $008,200,128,064,10,154,07A120,02,1,3,0,095,01A4,00D2,0010*\r\n
// ============================================================

module uart_reporter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  qber,
    input  wire [7:0]  snr_level,
    input  wire [7:0]  photon_rate,
    input  wire [7:0]  sifted_rate,
    input  wire [3:0]  power_level,
    input  wire [7:0]  basis_prob,
    input  wire [23:0] slot_width,
    input  wire [7:0]  rep_gap,
    input  wire [1:0]  adapt_mode,
    input  wire [2:0]  turb_level,
    input  wire        fade_active,
    input  wire [7:0]  irradiance,     // NEW: Gamma-Gamma combined I
    input  wire [15:0] total_qubits,
    input  wire [15:0] total_sifted,
    input  wire [15:0] total_errors,
    input  wire        window_pulse,
    input  wire        enable,
    output reg  [7:0]  uart_data,
    output reg         uart_start,
    input  wire        uart_busy
);

    reg [24:0] report_timer;
    wire timer_tick = (report_timer == 25'd25_000_000);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            report_timer <= 25'd0;
        else begin
            report_timer <= report_timer + 1'b1;
            if (timer_tick)
                report_timer <= 25'd0;
        end
    end

    reg [7:0]  msg_buf [0:79];
    reg [6:0]  msg_len;
    reg [6:0]  send_idx;
    
    localparam S_IDLE  = 2'd0;
    localparam S_BUILD = 2'd1;
    localparam S_SEND  = 2'd2;
    localparam S_WAIT  = 2'd3;
    
    reg [1:0] state;
    wire do_report = enable & (window_pulse | timer_tick);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            uart_start <= 1'b0;
            uart_data  <= 8'd0;
            send_idx   <= 7'd0;
            msg_len    <= 7'd0;
        end else begin
            uart_start <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    if (do_report)
                        state <= S_BUILD;
                end
                
                S_BUILD: begin
                    msg_buf[0]  <= "$";
                    // QBER (3 digits)
                    msg_buf[1]  <= hex_to_ascii(qber / 100);
                    msg_buf[2]  <= hex_to_ascii((qber / 10) % 10);
                    msg_buf[3]  <= hex_to_ascii(qber % 10);
                    msg_buf[4]  <= ",";
                    // SNR (3 digits)
                    msg_buf[5]  <= hex_to_ascii(snr_level / 100);
                    msg_buf[6]  <= hex_to_ascii((snr_level / 10) % 10);
                    msg_buf[7]  <= hex_to_ascii(snr_level % 10);
                    msg_buf[8]  <= ",";
                    // Photon (3 digits)
                    msg_buf[9]  <= hex_to_ascii(photon_rate / 100);
                    msg_buf[10] <= hex_to_ascii((photon_rate / 10) % 10);
                    msg_buf[11] <= hex_to_ascii(photon_rate % 10);
                    msg_buf[12] <= ",";
                    // Sifted (3 digits)
                    msg_buf[13] <= hex_to_ascii(sifted_rate / 100);
                    msg_buf[14] <= hex_to_ascii((sifted_rate / 10) % 10);
                    msg_buf[15] <= hex_to_ascii(sifted_rate % 10);
                    msg_buf[16] <= ",";
                    // Power (2 digits)
                    msg_buf[17] <= hex_to_ascii(power_level / 10);
                    msg_buf[18] <= hex_to_ascii(power_level % 10);
                    msg_buf[19] <= ",";
                    // Basis (3 digits)
                    msg_buf[20] <= hex_to_ascii(basis_prob / 100);
                    msg_buf[21] <= hex_to_ascii((basis_prob / 10) % 10);
                    msg_buf[22] <= hex_to_ascii(basis_prob % 10);
                    msg_buf[23] <= ",";
                    // Slot (6 hex)
                    msg_buf[24] <= nibble_to_hex(slot_width[23:20]);
                    msg_buf[25] <= nibble_to_hex(slot_width[19:16]);
                    msg_buf[26] <= nibble_to_hex(slot_width[15:12]);
                    msg_buf[27] <= nibble_to_hex(slot_width[11:8]);
                    msg_buf[28] <= nibble_to_hex(slot_width[7:4]);
                    msg_buf[29] <= nibble_to_hex(slot_width[3:0]);
                    msg_buf[30] <= ",";
                    // Gap (2 digits)
                    msg_buf[31] <= hex_to_ascii(rep_gap / 10);
                    msg_buf[32] <= hex_to_ascii(rep_gap % 10);
                    msg_buf[33] <= ",";
                    // Mode (1 digit)
                    msg_buf[34] <= hex_to_ascii({2'b00, adapt_mode});
                    msg_buf[35] <= ",";
                    // Turb (1 digit)
                    msg_buf[36] <= hex_to_ascii({1'b0, turb_level});
                    msg_buf[37] <= ",";
                    // Fade (1 digit)
                    msg_buf[38] <= fade_active ? "1" : "0";
                    msg_buf[39] <= ",";
                    // NEW: Irradiance (3 digits: 000-255)
                    msg_buf[40] <= hex_to_ascii(irradiance / 100);
                    msg_buf[41] <= hex_to_ascii((irradiance / 10) % 10);
                    msg_buf[42] <= hex_to_ascii(irradiance % 10);
                    msg_buf[43] <= ",";
                    // Total qubits (4 hex)
                    msg_buf[44] <= nibble_to_hex(total_qubits[15:12]);
                    msg_buf[45] <= nibble_to_hex(total_qubits[11:8]);
                    msg_buf[46] <= nibble_to_hex(total_qubits[7:4]);
                    msg_buf[47] <= nibble_to_hex(total_qubits[3:0]);
                    msg_buf[48] <= ",";
                    // Total sifted (4 hex)
                    msg_buf[49] <= nibble_to_hex(total_sifted[15:12]);
                    msg_buf[50] <= nibble_to_hex(total_sifted[11:8]);
                    msg_buf[51] <= nibble_to_hex(total_sifted[7:4]);
                    msg_buf[52] <= nibble_to_hex(total_sifted[3:0]);
                    msg_buf[53] <= ",";
                    // Total errors (4 hex)
                    msg_buf[54] <= nibble_to_hex(total_errors[15:12]);
                    msg_buf[55] <= nibble_to_hex(total_errors[11:8]);
                    msg_buf[56] <= nibble_to_hex(total_errors[7:4]);
                    msg_buf[57] <= nibble_to_hex(total_errors[3:0]);
                    // Terminator
                    msg_buf[58] <= "*";
                    msg_buf[59] <= "\r";
                    msg_buf[60] <= "\n";
                    
                    msg_len  <= 7'd61;
                    send_idx <= 7'd0;
                    state    <= S_SEND;
                end
                
                S_SEND: begin
                    if (send_idx >= msg_len)
                        state <= S_IDLE;
                    else if (!uart_busy) begin
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
    
    function [7:0] hex_to_ascii;
        input [7:0] val;
    begin
        if (val <= 8'd9)
            hex_to_ascii = "0" + val;
        else
            hex_to_ascii = "0";
    end
    endfunction
    
    function [7:0] nibble_to_hex;
        input [3:0] nib;
    begin
        if (nib <= 4'd9)
            nibble_to_hex = "0" + {4'd0, nib};
        else
            nibble_to_hex = "A" + {4'd0, nib - 4'd10};
    end
    endfunction

endmodule
