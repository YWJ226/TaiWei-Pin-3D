# ============================================================
# pdn_only_bottom.tcl
# Preserve the macro-placement handoff before the final PDN pass.
# ============================================================

# Core setup
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl

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

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting PDN bottom preparation"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
apply_tier_policy bottom -fixlib 1 -allow_net all

set pdn_script ""
if {[info exists ::env(PDN_TCL_BOTTOM)] && $::env(PDN_TCL_BOTTOM) ne ""} {
  set pdn_script $::env(PDN_TCL_BOTTOM)
}
if {$pdn_script eq "" || ![file exists $pdn_script]} {
  error "pdn_only_bottom.tcl: missing PDN script. Set PDN_TCL_BOTTOM."
}
source $pdn_script
cut_rows
if {[catch {pdngen} error_message]} {
  puts "bottom PDN failed: $error_message"
}
handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_manifest 1 \
  -write_image 1
exit
