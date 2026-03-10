// ============================================================
// UART TX — 115200 baud, 8N1
// ============================================================
// 50MHz / 115200 = 434 cycles per bit
// tx_start pulse → sends tx_data[7:0] → tx_busy goes LOW when done
// ============================================================

module uart_tx #(
    parameter CLK_FREQ = 50000000,
    parameter BAUD     = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  tx_data,
    input  wire        tx_start,
    output reg         tx_out,
    output reg         tx_busy
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;
    
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;
    
    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  data_reg;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            tx_out   <= 1'b1;
            tx_busy  <= 1'b0;
            clk_cnt  <= 16'd0;
            bit_idx  <= 3'd0;
            data_reg <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx_out  <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        data_reg <= tx_data;
                        tx_busy  <= 1'b1;
                        state    <= S_START;
                        clk_cnt  <= 16'd0;
                    end
                end
                
                S_START: begin
                    tx_out <= 1'b0;
                    if (clk_cnt < CLKS_PER_BIT - 1)
                        clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        clk_cnt <= 16'd0;
                        bit_idx <= 3'd0;
                        state   <= S_DATA;
                    end
                end
                
                S_DATA: begin
                    tx_out <= data_reg[bit_idx];
                    if (clk_cnt < CLKS_PER_BIT - 1)
                        clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        clk_cnt <= 16'd0;
                        if (bit_idx < 3'd7)
                            bit_idx <= bit_idx + 1'b1;
                        else
                            state <= S_STOP;
                    end
                end
                
                S_STOP: begin
                    tx_out <= 1'b1;
                    if (clk_cnt < CLKS_PER_BIT - 1)
                        clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        state   <= S_IDLE;
                        tx_busy <= 1'b0;
                    end
                end
            endcase
        end
    end

endmodule
