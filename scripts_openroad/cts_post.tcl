# ============================================================
# cts_post.tcl
# Run the opposite-tier OpenROAD post-CTS repair stage.
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
set stage_name "cts-post"
# Inputs : 4_0_cts.def / 4_0_cts.v / 4_0_cts.sdc / 4_0_cts.odb
# Outputs: 4_cts.def / 4_cts.v / 4_cts.sdc / 4_cts.odb
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
load_design $DEF_IN $SDC_IN "Starting POST CTS..."
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set before_report [file join $LOG_DIR "cts_post.before.nets"]
set after_report [file join $LOG_DIR "cts_post.after.nets"]
set summary_report [file join $LOG_DIR "cts_post.cross_tier.summary.rpt"]
set clock_before_report [file join $LOG_DIR "cts_post.clock.before.nets"]
set clock_after_report [file join $LOG_DIR "cts_post.clock.after.nets"]
set clock_summary_report [file join $LOG_DIR "cts_post.clock.cross_tier.summary.rpt"]

set fix_layer [or_cts_fix_tier]
set allow_net_class [expr {$fix_layer eq "upper" ? "upper-only" : "bottom-only"}]
apply_tier_policy $fix_layer -fixlib 1 -allow_net $allow_net_class -skip_clock_nets 1 -protect_split_buffers 0
report_cross_tier_snapshot $before_report -label "cts_post before"
report_cross_tier_snapshot $clock_before_report -label "cts_post clock before" -clock_only 1

utl::push_metrics_stage "cts__{}__pre_repair_timing"
estimate_parasitics -placement
utl::pop_metrics_stage

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

log_cmd repair_clock_nets
log_cmd detailed_placement
estimate_parasitics -placement

if {![info exists ::env(SKIP_CTS_REPAIR_TIMING)]} {
  set ::env(SKIP_CTS_REPAIR_TIMING) 0
}
if {!$::env(SKIP_CTS_REPAIR_TIMING)} {
  set ::env(SKIP_PIN_SWAP) 1
  repair_timing_helper
  set result [catch {detailed_placement} msg]
  if {$result != 0} {
    save_progress 4_cts_error
    puts "Detailed placement failed in CTS post: $msg"
    exit $result
  }
  check_placement -verbose
}

report_cross_tier_transition $summary_report $before_report $after_report -label "cts_post"
report_cross_tier_transition $clock_summary_report $clock_before_report $clock_after_report -label "cts_post clock" -clock_only 1

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 4 "cts_post" false false

handoff_write_stage_outputs $stage_paths \
  -write_db 1 \
  -write_def 1 \
  -write_verilog 1 \
  -write_sdc 1 \
  -write_image 1 \
  -write_manifest 1

exit
