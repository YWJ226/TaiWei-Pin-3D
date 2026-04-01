# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_place3D_upper.tcl
# Fix the bottom tier and run upper-tier preCTS optimization.
# ============================================================

# Core setup
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "place-upper"
# Inputs : ${DESIGN}_3D.tmp.def / ${DESIGN}_3D.tmp.v / 2_floorplan.sdc
# Outputs: ${DESIGN}_3D.tmp.def / ${DESIGN}_3D.tmp.v / 2_floorplan.sdc / ${DESIGN}_3d_after_upper.enc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/place_common.tcl
handoff_log_paths $stage_paths

handoff_init_design_from_paths $stage_paths

source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
set requested_allow_net [_requested_allow_net_class 0]
set effective_allow_net [_effective_allow_net_class $requested_allow_net]
set stage_tag [_allow_net_stage_tag $requested_allow_net]
set loop_stage [format "loop_upper_%s" [string map {- _} [_format_allow_net_class $requested_allow_net]]]
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
_report_allow_net_resolution "place-upper" $requested_allow_net $effective_allow_net
saveNetlist $before_netlist
extract_cross_tier_nets $before_report
set_tier_placement_status bottom fixed
apply_tier_policy upper -fixlib 1 -allow_net $effective_allow_net

pc::setup_basic
pc::run_place_step $loop_stage

set_tier_placement_status bottom placed
extract_cross_tier_nets $after_report
handoff_write_stage_outputs $stage_paths \
  -def_args {-floorplan} \
  -copy_sdc 0 \
  -save_design 1 \
  -write_png 1 \
  -write_manifest 1
saveNetlist $after_netlist
puts "INFO: 3D upper loop preCTS optimization done."
exit
