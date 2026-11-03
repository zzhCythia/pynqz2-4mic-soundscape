# PYNQ-Z2 Pmod B：I2S 时钟输出
set_property PACKAGE_PIN W14 [get_ports mic_sck]
set_property IOSTANDARD LVCMOS33 [get_ports mic_sck]

set_property PACKAGE_PIN Y14 [get_ports mic_ws]
set_property IOSTANDARD LVCMOS33 [get_ports mic_ws]

# PYNQ-Z2 Pmod B：两路麦克风数据输入
set_property PACKAGE_PIN T11 [get_ports {mic_sd[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {mic_sd[0]}]

set_property PACKAGE_PIN T10 [get_ports {mic_sd[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {mic_sd[1]}]

# PYNQ-Z2 Pmod B pin 7 (JB3_P) for WS2812 DIN.
set_property PACKAGE_PIN V16 [get_ports led_data]
set_property IOSTANDARD LVCMOS33 [get_ports led_data]
# PYNQ-Z2 HDMI OUT TMDS constraints

set_property -dict {PACKAGE_PIN J18 IOSTANDARD TMDS_33} [get_ports {TMDS_Data_p_0[2]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD TMDS_33} [get_ports {TMDS_Data_n_0[2]}]

set_property -dict {PACKAGE_PIN K19 IOSTANDARD TMDS_33} [get_ports {TMDS_Data_p_0[1]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD TMDS_33} [get_ports {TMDS_Data_n_0[1]}]

set_property -dict {PACKAGE_PIN K17 IOSTANDARD TMDS_33} [get_ports {TMDS_Data_p_0[0]}]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD TMDS_33} [get_ports {TMDS_Data_n_0[0]}]

set_property -dict {PACKAGE_PIN L16 IOSTANDARD TMDS_33} [get_ports {TMDS_Clk_p_0}]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD TMDS_33} [get_ports {TMDS_Clk_n_0}]