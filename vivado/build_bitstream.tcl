set project_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_dir pynqz2_4mic_features.xpr]
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
}
close_project
set overlay_dir [file join $project_dir realtime overlay]
file mkdir $overlay_dir
file copy -force [file join $project_dir pynqz2_4mic_features.runs impl_1 system_wrapper.bit] [file join $overlay_dir 4mic_realtime.bit]
file copy -force [file join $project_dir pynqz2_4mic_features.gen sources_1 bd system hw_handoff system.hwh] [file join $overlay_dir 4mic_realtime.hwh]
puts "Overlay ready in $overlay_dir"
