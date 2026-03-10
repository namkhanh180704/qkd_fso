# ============================================================
# bb84_phase2.sdc — Timing Constraints for BB84 QKD System
# Target: Altera Cyclone II EP2C20F484C7 (Terasic DE1)
# ============================================================
#
# FIX: Ring oscillator TRNG tạo combinational loops cố ý.
# TimeQuest không phân biệt được loop cố ý vs lỗi thiết kế
# → báo setup slack âm. File này khai báo false paths cho RO
# → TimeQuest bỏ qua các đường này khi tính timing.
#
# CÁCH THÊM VÀO PROJECT:
# 1. Copy file này vào thư mục project (cùng cấp .qpf)
# 2. Quartus → Assignments → Settings → TimeQuest Timing Analyzer
#    → SDC files → Add → chọn bb84_phase2.sdc
# 3. Recompile (Processing → Start Compilation)
# 4. Mở TimeQuest → verify setup slack > 0
# ============================================================

# ---- 1. Clock Definition ----
# DE1 board 50 MHz oscillator on PIN_L1
create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]

# ---- 2. Clock Uncertainty ----
# Account for PLL jitter and board-level clock skew
derive_clock_uncertainty

# ---- 3. FALSE PATHS — Ring Oscillator TRNG ----
# Ring oscillators are intentional combinational loops used
# for entropy generation. They must be excluded from STA.
#
# 3 instances of trng_random → each contains trng with 4 ROs:
#   gen_alice_data/trng_core/ro{0,1,2,3}_chain[*]
#   gen_alice_basis/trng_core/ro{0,1,2,3}_chain[*]
#   gen_bob_basis/trng_core/ro{0,1,2,3}_chain[*]

# Method 1: Cut all paths FROM ring oscillator chains
# This is the cleanest approach — RO outputs are async by nature
set_false_path -from [get_keepers {*trng_core*ro*_chain*}]

# Method 2 (backup): If Method 1 doesn't match all nodes,
# also cut by combinational loop detection
# Uncomment if needed:
# set_false_path -from [get_keepers {*ro0_chain*}]
# set_false_path -from [get_keepers {*ro1_chain*}]
# set_false_path -from [get_keepers {*ro2_chain*}]
# set_false_path -from [get_keepers {*ro3_chain*}]

# ---- 4. FALSE PATHS — Asynchronous Inputs ----
# DIP switches and push buttons are asynchronous
set_false_path -from [get_ports {SW[*]}]
set_false_path -from [get_ports {KEY[*]}]

# UART RX input is asynchronous (oversampled by uart_rx module)
set_false_path -from [get_ports {UART_RXD}]

# ---- 5. Output Constraints ----
# LEDs and 7-segment have no critical timing
set_false_path -to [get_ports {LEDR[*]}]
set_false_path -to [get_ports {LEDG[*]}]
set_false_path -to [get_ports {HEX0[*]}]
set_false_path -to [get_ports {HEX1[*]}]
set_false_path -to [get_ports {HEX2[*]}]
set_false_path -to [get_ports {HEX3[*]}]

# UART TX output
set_false_path -to [get_ports {UART_TXD}]

# GPIO (active only in external laser mode)
set_false_path -to [get_ports {GPIO_0[*]}]
set_false_path -from [get_ports {GPIO_0[*]}]
set_false_path -to [get_ports {GPIO_1[*]}]
set_false_path -from [get_ports {GPIO_1[*]}]
