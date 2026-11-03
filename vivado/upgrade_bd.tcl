# Run from Vivado: vivado -mode batch -source realtime/upgrade_bd.tcl
set project_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_dir pynqz2_4mic_features.xpr]
set bd_file [get_files */system.bd]
open_bd_design $bd_file

# Add the WS2812 serializer source to the project before refreshing the
# module reference.  The file is clocked from the existing 125 MHz PL clock.
set ws_file [file join $project_dir pynqz2_4mic_features.srcs sources_1 new ws2812_driver.v]
if {[llength [get_files -quiet $ws_file]] == 0} {
    add_files -norecurse $ws_file
}

# Refresh the module-reference ports after changing mic4_axis_top.v.
update_module_reference [get_ips system_mic4_axis_top_0_0]

if {[llength [get_bd_cells -quiet axi_gpio_capture]] == 0} {
    set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_capture]
    set_property -dict [list \
        CONFIG.C_IS_DUAL {1} \
        CONFIG.C_GPIO_WIDTH {32} \
        CONFIG.C_ALL_INPUTS {1} \
        CONFIG.C_GPIO2_WIDTH {1} \
        CONFIG.C_ALL_OUTPUTS_2 {1}] $gpio

    set_property CONFIG.NUM_MI {2} [get_bd_cells axi_smc]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] [get_bd_intf_pins axi_gpio_capture/S_AXI]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_gpio_capture/s_axi_aclk]
    connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins axi_gpio_capture/s_axi_aresetn]
    connect_bd_net [get_bd_pins mic4_axis_top_0/dropped_frames] [get_bd_pins axi_gpio_capture/gpio_io_i]
    connect_bd_net [get_bd_pins axi_gpio_capture/gpio2_io_o] [get_bd_pins mic4_axis_top_0/capture_en]
    assign_bd_address
}

# One 32-bit AXI GPIO register controls the LED index, enable, and RGB color.
if {[llength [get_bd_cells -quiet axi_gpio_led]] == 0} {
    set led_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_led]
    set_property -dict [list \
        CONFIG.C_IS_DUAL {0} \
        CONFIG.C_GPIO_WIDTH {32} \
        CONFIG.C_ALL_OUTPUTS {1}] $led_gpio
}

set_property CONFIG.NUM_MI {3} [get_bd_cells axi_smc]
if {[llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins axi_gpio_led/S_AXI]]] == 0} {
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] [get_bd_intf_pins axi_gpio_led/S_AXI]
}
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_gpio_led/s_axi_aclk]]] == 0} {
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_gpio_led/s_axi_aclk]
}
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_gpio_led/s_axi_aresetn]]] == 0} {
    connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins axi_gpio_led/s_axi_aresetn]
}
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_gpio_led/gpio_io_o]]] == 0} {
    connect_bd_net [get_bd_pins axi_gpio_led/gpio_io_o] [get_bd_pins mic4_axis_top_0/led_control]
}

# The capture GPIO may already exist when this script is rerun.  Assign the
# address for the newly added LED GPIO unconditionally so PYNQ exposes it.
assign_bd_address

if {[llength [get_bd_ports -quiet led_data]] == 0} {
    set led_port [create_bd_port -dir O led_data]
    connect_bd_net [get_bd_pins mic4_axis_top_0/led_data] $led_port
} elseif {[llength [get_bd_nets -quiet -of_objects [get_bd_ports led_data]]] == 0} {
    connect_bd_net [get_bd_pins mic4_axis_top_0/led_data] [get_bd_ports led_data]
}

validate_bd_design
save_bd_design
generate_target all $bd_file
update_compile_order -fileset sources_1
close_project
