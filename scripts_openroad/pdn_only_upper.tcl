# ============================================================
# pdn_only_upper.tcl
# Run the final OpenROAD PDN generation pass and publish 2_floorplan.*.
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
set stage_name "pdn-upper"
# Inputs : 2_6_floorplan_pdn_bottom.def / 2_6_floorplan_pdn_bottom.v / 1_synth.sdc
# Outputs: 2_6_floorplan_pdn.def / 2_6_floorplan_pdn.v / 2_floorplan.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting PDN Generation"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/floorplan_utils.tcl
apply_tier_policy upper -fixlib 1 -allow_net all

set pdn_script ""
if {[info exists ::env(PDN_TCL_UPPER)] && $::env(PDN_TCL_UPPER) ne ""} {
  set pdn_script $::env(PDN_TCL_UPPER)
}
if {$pdn_script eq "" || ![file exists $pdn_script]} {
  error "pdn_only_upper.tcl: missing PDN script. Set PDN_TCL_UPPER."
}
source $pdn_script

if { [info exists ::env(POST_PDN_TCL)] && [file exists $::env(POST_PDN_TCL)] } {
  source $::env(POST_PDN_TCL)
}

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_manifest 1
exit
