# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ===============================
# innovus_place3D_bottom.tcl — fix upper, run bottom loop preCTS opt
# ===============================
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/place_common.tcl

set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]

set GPDEF     [file join $RESULTS_DIR "${DESIGN}_3D.tmp.def"]
set GPVERILOG [file join $RESULTS_DIR "${DESIGN}_3D.tmp.v"]
set sdc       [file join $RESULTS_DIR "1_synth.sdc"]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog $GPVERILOG
set init_design_netlisttype "Verilog"

init_design -setup {WC_VIEW} -hold {BC_VIEW}
_common_setup

defIn $GPDEF

source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
set allow_net [_requested_allow_net_class 0]
set stage_tag [_allow_net_stage_tag $allow_net]
set loop_stage [format "loop_bottom_%s" [string map {- _} [_format_allow_net_class $allow_net]]]
if {$stage_tag eq ""} {
  set before_netlist [file join $RESULTS_DIR "${DESIGN}_3D.bottom.before.v"]
  set after_netlist [file join $RESULTS_DIR "${DESIGN}_3D.bottom.v"]
  set before_report [file join $LOG_DIR "place_3d_bottom.before.nets"]
  set after_report [file join $LOG_DIR "place_3d_bottom.after.nets"]
} else {
  set before_netlist [file join $RESULTS_DIR "${DESIGN}_3D.bottom${stage_tag}.before.v"]
  set after_netlist [file join $RESULTS_DIR "${DESIGN}_3D.bottom${stage_tag}.v"]
  set before_report [file join $LOG_DIR "place_3d_bottom${stage_tag}.before.nets"]
  set after_report [file join $LOG_DIR "place_3d_bottom${stage_tag}.after.nets"]
}
puts "INFO: bottom loop preCTS allow_net = [_format_allow_net_class $allow_net]"
saveNetlist $before_netlist
extract_cross_tier_nets $before_report
set_tier_placement_status upper fixed
apply_tier_policy bottom -fixlib 1 -allow_net $allow_net

pc::setup_basic
pc::run_loop_opt_step $loop_stage

set_tier_placement_status upper placed
extract_cross_tier_nets $after_report
# Export
saveDesign [file join $::env(OBJECTS_DIR) "${DESIGN}_3d_after_bottom.enc"]
defOut -floorplan $GPDEF
saveNetlist [file join $RESULTS_DIR "${DESIGN}_3D.tmp.v"]
saveNetlist $after_netlist
fit
dumpToGIF $LOG_DIR/3_place_bottom.png
puts "INFO: 3D bottom loop preCTS optimization done."
exit
