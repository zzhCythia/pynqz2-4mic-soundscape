# Source this file in the Vivado Tcl Console with the display project open.
# It replaces only the colour-bar generator and reuses its AXI connection.
set script_dir [file dirname [file normalize [info script]]]
set rtl_file [file join $script_dir soundscape_axis_video.v]
if {![file exists $rtl_file]} { error "Missing $rtl_file" }
if {[llength [get_files -quiet $rtl_file]] == 0} {
    add_files -fileset sources_1 $rtl_file
}
update_compile_order -fileset sources_1

set bd_file [lindex [get_files -all -quiet -filter {NAME =~ *system.bd}] 0]
if {$bd_file eq ""} { error "Open the pynqz2_4mic_display project first" }
open_bd_design $bd_file
if {[llength [get_bd_cells -quiet soundscape_video_0]]} {
    error "soundscape_video_0 already exists; patch was previously applied"
}
if {![llength [get_bd_cells -quiet v_tpg_0]]} {
    error "Expected v_tpg_0 in system.bd; inspect this project's HDMI design"
}
if {![llength [get_bd_intf_pins -quiet axi_smc/M04_AXI]]} {
    error "Expected axi_smc/M04_AXI, previously used by v_tpg_0"
}

set bd_path [get_property NAME $bd_file]
file copy -force $bd_path "${bd_path}.before_soundscape"
create_bd_cell -type module -reference soundscape_axis_video soundscape_video_0
if {![llength [get_bd_intf_pins -quiet soundscape_video_0/M_AXIS_VIDEO]]} {
    error "Module reference has no M_AXIS_VIDEO interface; check RTL AXIS attributes"
}
delete_bd_objs [get_bd_cells v_tpg_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_visual
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {32} \
    CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_ALL_OUTPUTS_2 {1}] [get_bd_cells axi_gpio_visual]

connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] \
    [get_bd_intf_pins axi_gpio_visual/S_AXI]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
    [get_bd_pins axi_gpio_visual/s_axi_aclk]
connect_bd_net [get_bd_pins rst_clk_wiz_0_74M/peripheral_aresetn] \
    [get_bd_pins axi_gpio_visual/s_axi_aresetn]
connect_bd_net [get_bd_pins axi_gpio_visual/gpio_io_o] \
    [get_bd_pins soundscape_video_0/ctrl0]
connect_bd_net [get_bd_pins axi_gpio_visual/gpio2_io_o] \
    [get_bd_pins soundscape_video_0/ctrl1]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
    [get_bd_pins soundscape_video_0/aclk]
connect_bd_net [get_bd_pins rst_clk_wiz_0_74M/peripheral_aresetn] \
    [get_bd_pins soundscape_video_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins soundscape_video_0/M_AXIS_VIDEO] \
    [get_bd_intf_pins v_axi4s_vid_out_0/video_in]

# This was the wire that made the standalone HDMI colour bars work.
if {![llength [get_bd_nets -quiet -of_objects \
        [get_bd_pins v_tc_0/gen_clken]]]} {
    connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vtg_ce] \
        [get_bd_pins v_tc_0/gen_clken]
}

assign_bd_address
validate_bd_design
save_bd_design
generate_target all $bd_file
update_compile_order -fileset sources_1
puts "Soundscape video source installed. Check Address Editor for axi_gpio_visual, then generate a new bitstream."
