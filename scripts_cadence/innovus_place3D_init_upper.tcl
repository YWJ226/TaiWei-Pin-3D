# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_place3D_init_upper.tcl
# Run upper-tier incremental place initialization.
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
set stage_name "place-init-upper"
# Inputs : ${DESIGN}_3D.tmp.def / ${DESIGN}_3D.tmp.v / 2_floorplan.sdc
# Outputs: ${DESIGN}_3D.tmp.def / ${DESIGN}_3D.tmp.v / 2_floorplan.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/place_common.tcl
source $::env(CADENCE_SCRIPTS_DIR)/place_macro_util.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
handoff_log_paths $stage_paths

handoff_init_design_from_paths $stage_paths

pmu::set_all_tier_macros_fixed
set_tier_placement_status bottom fixed
saveNetlist [file join $RESULTS_DIR "${DESIGN}_3D.init_upper.before.v"]
extract_cross_tier_nets [file join $LOG_DIR "place_3d_init_upper.before.nets"]
set requested_allow_net [_normalize_allow_net_class "upper-only"]
set effective_allow_net [_effective_allow_net_class $requested_allow_net]
_report_allow_net_resolution "place-init-upper" $requested_allow_net $effective_allow_net
apply_tier_policy upper -fixlib 1 -allow_net $effective_allow_net

pc::setup_basic
pc::run_global_place_step place_init_upper

pmu::set_all_tier_macros_fixed
set_tier_placement_status bottom placed
extract_cross_tier_nets [file join $LOG_DIR "place_3d_init_upper.after.nets"]
saveNetlist [file join $RESULTS_DIR "${DESIGN}_3D.init_upper.after.v"]

handoff_write_stage_outputs $stage_paths \
  -def_args {-floorplan} \
  -copy_sdc 0 \
  -save_design 0 \
  -write_png 1 \
  -write_manifest 1
# Print completion message
puts "INFO: 3D upper tier incremental init done. DEF: [handoff_get $stage_paths def_out]  V: [handoff_get $stage_paths v_out]"

# Exit the tool
exit
