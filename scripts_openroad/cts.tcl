# ============================================================
# cts.tcl
# Run the owner-tier OpenROAD CTS stage.
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
set stage_name "cts"
# Inputs : 3_place.def / 3_place.v / 3_place.sdc
# Outputs: 4_0_cts.def / 4_0_cts.v / 4_0_cts.sdc / 4_0_cts.odb
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

proc save_progress {stage_name} {
  puts "Run 'make gui_${stage_name}.odb' to load progress snapshot"
  write_db $::env(RESULTS_DIR)/${stage_name}.odb
  write_sdc -no_timestamp $::env(RESULTS_DIR)/${stage_name}.sdc
}

# Additional setup
handoff_log_paths $stage_paths
utl::set_metrics_stage "cts__{}"
load_design $DEF_IN $SDC_IN "Starting CTS..."
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set before_report [file join $LOG_DIR "cts.before.nets"]
set after_report [file join $LOG_DIR "cts.after.nets"]
set summary_report [file join $LOG_DIR "cts.cross_tier.summary.rpt"]
set clock_before_report [file join $LOG_DIR "cts.clock.before.nets"]
set clock_after_report [file join $LOG_DIR "cts.clock.after.nets"]
set clock_summary_report [file join $LOG_DIR "cts.clock.cross_tier.summary.rpt"]

set cts_layer [or_cts_owner_tier]
set allow_net_class [expr {$cts_layer eq "upper" ? "upper-only" : "bottom-only"}]
apply_tier_policy $cts_layer -fixlib 1 -allow_net $allow_net_class  -skip_clock_nets 1 -protect_split_buffers 0
report_cross_tier_snapshot $before_report -label "cts before"
report_cross_tier_snapshot $clock_before_report -label "cts clock before" -clock_only 1

log_cmd repair_clock_inverters

set cts_args [list \
  -sink_clustering_enable \
  -repair_clock_nets]
append_env_var cts_args CTS_BUF_DISTANCE -distance_between_buffers 1
append_env_var cts_args CTS_CLUSTER_SIZE -sink_clustering_size 1
append_env_var cts_args CTS_CLUSTER_DIAMETER -sink_clustering_max_diameter 1
append_env_var cts_args CTS_BUF_LIST -buf_list 1
append_env_var cts_args CTS_LIB_NAME -library 1

if {[env_var_exists_and_non_empty CTS_ARGS]} {
  set cts_args $::env(CTS_ARGS)
}

log_cmd clock_tree_synthesis {*}$cts_args

utl::push_metrics_stage "cts__{}__pre_repair_timing"
estimate_parasitics -placement
utl::pop_metrics_stage

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

log_cmd repair_clock_nets
catch {log_cmd detailed_placement}
estimate_parasitics -placement

if {![info exists ::env(SKIP_CTS_REPAIR_TIMING)]} {
  set ::env(SKIP_CTS_REPAIR_TIMING) 0
}
if {!$::env(SKIP_CTS_REPAIR_TIMING)} {
  set ::env(SKIP_PIN_SWAP) 1
  repair_timing_helper
  set result [catch {detailed_placement} msg]
  if {$result != 0} {
    save_progress 4_0_cts_error
    puts "Detailed placement failed in CTS: $msg"
    exit $result
  }
  check_placement -verbose
}

report_cross_tier_transition $summary_report $before_report $after_report -label "cts"
report_cross_tier_transition $clock_summary_report $clock_before_report $clock_after_report -label "cts clock" -clock_only 1

source_env_var_if_exists POST_CTS_TCL
source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 4 "cts" false false

handoff_write_stage_outputs $stage_paths \
  -write_db 1 \
  -write_def 1 \
  -write_verilog 1 \
  -write_sdc 1 \
  -write_image 1 \
  -write_manifest 1

exit
