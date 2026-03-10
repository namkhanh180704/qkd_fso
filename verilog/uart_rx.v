// ============================================================
// UART RX — 115200 baud, 8N1 Receiver
// ============================================================
// Receives bytes from PC (Alice's qubit commands)
// rx_valid = 1-cycle pulse when new byte is available in rx_data
//
// Protocol: PC sends 1 byte per qubit:
//   Bit[7]   = 1 → qubit command (0 → control command)
//   Bit[2]   = alice_data
//   Bit[1]   = alice_basis
//   Bit[0]   = bob_basis (if pc_bob_mode=1, else FPGA uses own TRNG)
//
// Control commands (bit[7]=0):
//   0x01 = Reset statistics
//   0x02 = Request status report
//   0x03 = Batch mode: next byte = count N, auto-process N qubits
// ============================================================

module uart_rx #(
    parameter CLK_FREQ = 50000000,
    parameter BAUD     = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx_in,       // UART_RXD pin
    output reg  [7:0]  rx_data,     // Received byte
    output reg         rx_valid,    // 1-cycle pulse: new byte ready
    output reg         rx_busy      // Currently receiving
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;          // 434 @ 50MHz/115200
    localparam HALF_BIT     = CLKS_PER_BIT / 2;         // 217

    localparam S_IDLE  = 3'd0;
    localparam S_START = 3'd1;
    localparam S_DATA  = 3'd2;
    localparam S_STOP  = 3'd3;
    localparam S_DONE  = 3'd4;

    reg [2:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  data_shift;

    // ---- Double-register input for metastability ----
    reg rx_sync1, rx_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx_in;
            rx_sync2 <= rx_sync1;
        end
    end

    // ---- Receiver FSM ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            rx_data    <= 8'd0;
            rx_valid   <= 1'b0;
            rx_busy    <= 1'b0;
            clk_cnt    <= 16'd0;
            bit_idx    <= 3'd0;
            data_shift <= 8'd0;
        end else begin
            rx_valid <= 1'b0;   // Default: pulse cleared

            case (state)
                S_IDLE: begin
                    rx_busy <= 1'b0;
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    // Detect start bit (falling edge → LOW)
                    if (rx_sync2 == 1'b0) begin
                        state   <= S_START;
                        rx_busy <= 1'b1;
                    end
                end

                S_START: begin
                    // Wait half bit period → sample middle of start bit
                    if (clk_cnt < HALF_BIT - 1)
                        clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        clk_cnt <= 16'd0;
                        if (rx_sync2 == 1'b0)
                            state <= S_DATA;    // Valid start bit
                        else
                            state <= S_IDLE;    // False start, abort
                    end
                end

                S_DATA: begin
                    // Wait full bit period → sample middle of data bit
                    if (clk_cnt < CLKS_PER_BIT - 1)
                        clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        clk_cnt <= 16'd0;
                        data_shift[bit_idx] <= rx_sync2;  // LSB first
                        if (bit_idx == 3'd7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1'b1;
                    end
                end

                S_STOP: begin
                    // Wait full bit period for stop bit
                    if (clk_cnt < CLKS_PER_BIT - 1)
                        clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        state    <= S_DONE;
                        rx_data  <= data_shift;
                        rx_valid <= 1'b1;   // Output valid byte
                    end
                end

                S_DONE: begin
                    // Single-cycle gap before accepting next byte
                    state   <= S_IDLE;
                    rx_busy <= 1'b0;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
