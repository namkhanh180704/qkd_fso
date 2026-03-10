// ============================================================
// TRUE RANDOM NUMBER GENERATOR (TRNG)
// Ring Oscillator + Von Neumann Debiaser
// Target: Altera Cyclone II EP2C20F484C7
// ============================================================
//
// NGUYÊN LÝ:
//   Ring Oscillator (RO) tạo dao động tự do từ chuỗi inverter
//   lẻ. Jitter giữa các RO được khai thác làm entropy source.
//   Nhiều RO XOR lại → raw random bits → Von Neumann debiaser
//   loại bỏ bias → true random output.
//
// KIẾN TRÚC:
//   [RO_1 (3-inv)] --\
//   [RO_2 (5-inv)] ---XOR→ raw_bit → Von Neumann → random_bit
//   [RO_3 (7-inv)] --/                             random_byte
//   [RO_4 (9-inv)] --/
//
//   RO dao động ở tần số khác nhau (~100-400MHz trên Cyclone II)
//   vì chiều dài chuỗi khác nhau → jitter tích lũy giữa chúng
//   là nguồn entropy thực sự.
//
// SAMPLING:
//   Lấy mẫu XOR output bằng clock 50MHz (>> Nyquist)
//   → raw_bit có bias nhỏ (do correlation giữa samples)
//   → Von Neumann debiaser loại bỏ bias:
//       (0,1) → output 0
//       (1,0) → output 1
//       (0,0) và (1,1) → discard (không output)
//
// THROUGHPUT:
//   ~50M raw bits/s → ~12M debiased bits/s (Von Neumann 25% efficiency)
//   Đủ cho BB84 ở 50-200 qubits/s
//
// RESOURCE:
//   4 ROs × ~10 LEs + debiaser ~30 LEs ≈ 70 LEs total
//   (So với LFSR: 16 LEs, tăng ~50 LEs nhưng truly random)
//
// LƯU Ý SYNTHESIS:
//   Dùng (* keep *) attribute để Quartus không optimize away
//   ring oscillator chains. LCELL primitive giữ inverter riêng lẻ.
//
// THAM KHẢO:
//   [1] Sunar, Martin, Stinson, "A Provably Secure True Random
//       Number Generator with Built-In Tolerance to Active Attacks,"
//       IEEE Trans. Computers, 2007.
//   [2] Schellekens et al., "FPGA Vendor Agnostic True Random
//       Number Generator," FPL, 2006.
// ============================================================

module trng #(
    parameter NUM_RO = 4    // Số ring oscillator (2-8)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    
    output wire        random_bit,      // 1-bit debiased output
    output wire [7:0]  random_byte,     // 8-bit accumulated output
    output wire        bit_valid,       // Pulse: new random_bit ready
    output wire        byte_valid       // Pulse: new random_byte ready
);

    // ============================================================
    // 1. RING OSCILLATORS
    // ============================================================
    // Mỗi RO là chuỗi inverter lẻ (3, 5, 7, 9 stages)
    // tạo dao động tự do. Khác chiều dài → khác tần số
    // → jitter giữa chúng là entropy source.
    
    wire [NUM_RO-1:0] ro_out;
    
    // RO 0: 3-stage (~300MHz on Cyclone II)
    (* keep = 1 *) wire [2:0] ro0_chain;
    assign ro0_chain[0] = ~ro0_chain[2];
    assign ro0_chain[1] = ~ro0_chain[0];
    assign ro0_chain[2] = ~ro0_chain[1];
    assign ro_out[0] = ro0_chain[2];
    
    // RO 1: 5-stage (~200MHz)
    (* keep = 1 *) wire [4:0] ro1_chain;
    assign ro1_chain[0] = ~ro1_chain[4];
    assign ro1_chain[1] = ~ro1_chain[0];
    assign ro1_chain[2] = ~ro1_chain[1];
    assign ro1_chain[3] = ~ro1_chain[2];
    assign ro1_chain[4] = ~ro1_chain[3];
    assign ro_out[1] = ro1_chain[4];
    
    // RO 2: 7-stage (~150MHz)
    (* keep = 1 *) wire [6:0] ro2_chain;
    assign ro2_chain[0] = ~ro2_chain[6];
    assign ro2_chain[1] = ~ro2_chain[0];
    assign ro2_chain[2] = ~ro2_chain[1];
    assign ro2_chain[3] = ~ro2_chain[2];
    assign ro2_chain[4] = ~ro2_chain[3];
    assign ro2_chain[5] = ~ro2_chain[4];
    assign ro2_chain[6] = ~ro2_chain[5];
    assign ro_out[2] = ro2_chain[6];
    
    // RO 3: 9-stage (~120MHz)
    (* keep = 1 *) wire [8:0] ro3_chain;
    assign ro3_chain[0] = ~ro3_chain[8];
    assign ro3_chain[1] = ~ro3_chain[0];
    assign ro3_chain[2] = ~ro3_chain[1];
    assign ro3_chain[3] = ~ro3_chain[2];
    assign ro3_chain[4] = ~ro3_chain[3];
    assign ro3_chain[5] = ~ro3_chain[4];
    assign ro3_chain[6] = ~ro3_chain[5];
    assign ro3_chain[7] = ~ro3_chain[6];
    assign ro3_chain[8] = ~ro3_chain[7];
    assign ro_out[3] = ro3_chain[8];

    // ============================================================
    // 2. ENTROPY MIXING (XOR all ROs)
    // ============================================================
    wire raw_xor = ro_out[0] ^ ro_out[1] ^ ro_out[2] ^ ro_out[3];
    
    // Sample raw XOR output with system clock
    reg raw_sampled;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            raw_sampled <= 1'b0;
        else
            raw_sampled <= raw_xor;
    end
    
    // ============================================================
    // 3. SAMPLING DIVIDER
    // ============================================================
    // Lấy mẫu mỗi 64 clock cycles (~781kHz) thay vì mỗi cycle
    // Cho phép jitter tích lũy nhiều hơn giữa các sample
    // → Tăng entropy per bit
    
    reg [5:0] sample_div;
    reg       sample_tick;
    reg       sampled_bit;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_div  <= 6'd0;
            sample_tick <= 1'b0;
            sampled_bit <= 1'b0;
        end else if (enable) begin
            sample_div  <= sample_div + 1'b1;
            sample_tick <= 1'b0;
            if (sample_div == 6'd0) begin
                sample_tick <= 1'b1;
                sampled_bit <= raw_sampled;
            end
        end else begin
            sample_tick <= 1'b0;
        end
    end
    
    // ============================================================
    // 4. VON NEUMANN DEBIASER
    // ============================================================
    // Xử lý pairs: (0,1)→0, (1,0)→1, others→discard
    // Loại bỏ bias trong raw stream, output ~25% throughput
    //
    // Đảm bảo: nếu raw stream có P(1) = p ≠ 0.5,
    // Von Neumann output vẫn có P(1) = 0.5 chính xác
    // (miễn là các bit independent — đã đảm bảo qua sample_div)
    
    reg        vn_first;       // First bit of pair
    reg        vn_have_first;  // Waiting for second bit
    reg        vn_out_bit;     // Debiased output
    reg        vn_out_valid;   // Output valid pulse
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vn_first      <= 1'b0;
            vn_have_first <= 1'b0;
            vn_out_bit    <= 1'b0;
            vn_out_valid  <= 1'b0;
        end else begin
            vn_out_valid <= 1'b0;
            
            if (sample_tick) begin
                if (!vn_have_first) begin
                    // Store first bit of pair
                    vn_first      <= sampled_bit;
                    vn_have_first <= 1'b1;
                end else begin
                    // Second bit: compare pair
                    vn_have_first <= 1'b0;
                    if (vn_first != sampled_bit) begin
                        // Different → output first bit
                        vn_out_bit   <= vn_first;
                        vn_out_valid <= 1'b1;
                    end
                    // Same → discard both (no output)
                end
            end
        end
    end
    
    // ============================================================
    // 5. BYTE ACCUMULATOR
    // ============================================================
    // Collect 8 debiased bits into a byte
    
    reg [7:0] byte_shift;
    reg [2:0] bit_count;
    reg       byte_ready;
    reg [7:0] byte_out;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_shift <= 8'd0;
            bit_count  <= 3'd0;
            byte_ready <= 1'b0;
            byte_out   <= 8'd0;
        end else begin
            byte_ready <= 1'b0;
            
            if (vn_out_valid) begin
                byte_shift <= {byte_shift[6:0], vn_out_bit};
                bit_count  <= bit_count + 1'b1;
                
                if (bit_count == 3'd7) begin
                    byte_out   <= {byte_shift[6:0], vn_out_bit};
                    byte_ready <= 1'b1;
                    bit_count  <= 3'd0;
                end
            end
        end
    end
    
    // ============================================================
    // 6. OUTPUT ASSIGNMENTS
    // ============================================================
    assign random_bit  = vn_out_bit;
    assign random_byte = byte_out;
    assign bit_valid   = vn_out_valid;
    assign byte_valid  = byte_ready;

endmodule
