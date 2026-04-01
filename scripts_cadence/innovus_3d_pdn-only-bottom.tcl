# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# innovus_3d_pdn-only-bottom.tcl
# Build bottom-tier PDN only.
# ==========================================

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
set stage_name "pdn-bottom"
# Inputs : 2_5_place_macro_bottom.def / 2_5_place_macro_bottom.v / 1_synth.sdc
# Outputs: 2_6_floorplan_pdn_bottom.def / 2_6_floorplan_pdn_bottom.v / 1_synth.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
handoff_log_paths $stage_paths

handoff_init_design_from_paths $stage_paths

if {[info exists ::env(BOTTOM_SITE)] && $::env(BOTTOM_SITE) ne ""} {
    rebuild_rows_for_site $::env(BOTTOM_SITE) bottom
} else {
    rebuild_rows_for_site $::env(PLACE_SITE) bottom
}

source $::env(PLATFORM_DIR)/util/pdn_config_bottom.tcl

handoff_write_stage_outputs $stage_paths \
  -def_args {-floorplan} \
  -copy_sdc 0 \
  -save_design 0 \
  -write_png 1 \
  -write_manifest 1

puts "INFO: Bottom-tier PDN stage done."
exit
