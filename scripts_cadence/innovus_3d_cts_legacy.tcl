# ============================================================
# innovus_3d_cts_legacy.tcl
# Legacy CTS baseline kept for robustness comparison.
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
set stage_name "cts-legacy"
# Inputs : 3_place.def / 3_place.v / 3_place.sdc
# Outputs: 4_1_cts.def / 4_1_cts.v / 4_1_cts.sdc / 4_cts.def / 4_cts.v / 4_cts.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
handoff_log_paths $stage_paths

setMultiCpuUsage -localCpu [_get NUM_CORES 16]

setGenerateViaMode -auto true
handoff_prepare_init_globals $stage_paths
init_design -setup {WC_VIEW} -hold {BC_VIEW}
set_power_analysis_mode -leakage_power_view WC_VIEW -dynamic_power_view WC_VIEW
set_interactive_constraint_modes {CON}
setAnalysisMode -reset
setAnalysisMode -analysisType onChipVariation -cppr both
defIn $DEF_IN

if {[info exists ::env(MAX_ROUTING_LAYER)]} {
  setDesignMode -topRoutingLayer $::env(MAX_ROUTING_LAYER)
}
if {[info exists ::env(MIN_ROUTING_LAYER)]} {
  setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER)
}

set_ccopt_property post_conditioning_enable_routing_eco 1
set_ccopt_property -cts_def_lock_clock_sinks_after_routing true
setOptMode -unfixClkInstForOpt false

set active_tier "bottom"
set fixed_tier "upper"
if {[info exists ::env(CTS_LAYER)] && $::env(CTS_LAYER) ne ""} {
  set active_tier [string tolower $::env(CTS_LAYER)]
  if {$active_tier eq "upper"} {
    set fixed_tier "bottom"
  }
}
source $::env(CADENCE_SCRIPTS_DIR)/cts_stage_common.tcl
set cts_policy_stage "owner-tree"
set requested_allow_net [cts_owner_requested_allow_net]
set effective_allow_net [cts_owner_allow_net]
_report_allow_net_resolution "cts-legacy" $requested_allow_net $effective_allow_net
puts "INFO: Running staged 3D CTS stage '$cts_policy_stage' (owner=[cts_owner_tier], receive=[cts_receive_tier], requested_allow_net=[_format_allow_net_class $requested_allow_net], effective_allow_net=[_format_allow_net_class $effective_allow_net])."

extract_cross_tier_nets [file join $LOG_DIR "cts_legacy.before.nets"] -clock_only 1
set_tier_placement_status $fixed_tier fixed
apply_tier_policy $active_tier -fixlib 1 -allow_net $effective_allow_net

create_ccopt_clock_tree_spec
ccopt_design

set_tier_placement_status $fixed_tier placed
extract_cross_tier_nets [file join $LOG_DIR "cts_legacy.after.nets"] -clock_only 1

handoff_write_stage_outputs $stage_paths \
  -def_args {-floorplan -routing} \
  -copy_sdc 1 \
  -save_design 0 \
  -write_png 1 \
  -write_manifest 1 \
  -extra_manifest [list \
    owner_tier [cts_owner_tier] \
    receive_tier [cts_receive_tier]]
puts "INFO: Legacy CTS done. DEF -> [lindex [handoff_get $stage_paths def_aliases] 0]  V -> [lindex [handoff_get $stage_paths v_aliases] 0]  SDC -> [lindex [handoff_get $stage_paths sdc_aliases] 0]"
exit
