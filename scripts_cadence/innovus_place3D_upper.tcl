# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ===============================
# innovus_place3D_upper.tcl — fix bottom, run upper loop preCTS opt
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
set loop_stage [format "loop_upper_%s" [string map {- _} [_format_allow_net_class $allow_net]]]
if {$stage_tag eq ""} {
  set before_netlist [file join $RESULTS_DIR "${DESIGN}_3D.upper.before.v"]
  set after_netlist [file join $RESULTS_DIR "${DESIGN}_3D.upper.v"]
  set before_report [file join $LOG_DIR "place_3d_upper.before.nets"]
  set after_report [file join $LOG_DIR "place_3d_upper.after.nets"]
} else {
  set before_netlist [file join $RESULTS_DIR "${DESIGN}_3D.upper${stage_tag}.before.v"]
  set after_netlist [file join $RESULTS_DIR "${DESIGN}_3D.upper${stage_tag}.v"]
  set before_report [file join $LOG_DIR "place_3d_upper${stage_tag}.before.nets"]
  set after_report [file join $LOG_DIR "place_3d_upper${stage_tag}.after.nets"]
}
puts "INFO: upper loop preCTS allow_net = [_format_allow_net_class $allow_net]"
saveNetlist $before_netlist
extract_cross_tier_nets $before_report
set_tier_placement_status bottom fixed
apply_tier_policy upper -fixlib 1 -allow_net $allow_net

pc::setup_basic
pc::run_loop_opt_step $loop_stage

set_tier_placement_status bottom placed
extract_cross_tier_nets $after_report
# Export
saveDesign [file join $::env(OBJECTS_DIR) "${DESIGN}_3d_after_upper.enc"]
defOut -floorplan $GPDEF
saveNetlist [file join $RESULTS_DIR "${DESIGN}_3D.tmp.v"]
saveNetlist $after_netlist
fit
dumpToGIF $LOG_DIR/3_place_upper.png
puts "INFO: 3D upper loop preCTS optimization done."
exit
