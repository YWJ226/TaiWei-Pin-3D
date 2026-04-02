# ============================================================
# split_net_stage.tcl
# Run the OpenROAD 3D mixed-tier split pass or pass-through mode.
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
set stage_name "split-net"
# Inputs : 2_4_floorplan_io.def / 2_4_floorplan_io.v / 1_synth.sdc
# Outputs: 2_4_floorplan_io.def / 2_4_floorplan_io.v / 1_synth.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

proc _write_split_summary {path mode stats_dict} {
  set fh [open $path w]
  puts $fh "mode $mode"
  foreach key {candidate_nets mixed_tier_nets split_nets processed_residual} {
    if {[dict exists $stats_dict $key]} {
      puts $fh "$key [dict get $stats_dict $key]"
    }
  }
  if {[dict exists $stats_dict skip_reason_counts]} {
    set skip_reason_counts [dict get $stats_dict skip_reason_counts]
    if {[llength $skip_reason_counts] > 0} {
      puts $fh "skip_reasons"
      foreach {reason count} $skip_reason_counts {
        puts $fh "  $reason $count"
      }
    }
  }
  close $fh
}

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting split-net stage"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/split_net.tcl

set before_report [file join $LOG_DIR "split_net.before.nets"]
set after_report  [file join $LOG_DIR "split_net.after.nets"]
set action_report [file join $LOG_DIR "split_net.actions.rpt"]
set cross_tier_summary_report [file join $LOG_DIR "split_net.cross_tier.summary.rpt"]
set split_mode "enabled"

set before_stats [extract_cross_tier_net_stats $before_report]

if {[pin3d_split_net_flow_enabled]} {
  lassign [ord::get_die_area] die_lx die_ly die_ux die_uy
  set split_y_um [expr {($die_ly + $die_uy) / 2.0}]
  namespace eval ::tier_split_or2 [list variable CFG]
  set ::tier_split_or2::CFG(split_y_um) $split_y_um
  set ::tier_split_or2::CFG(dry_run) 0
  set ::tier_split_or2::CFG(report_file) $action_report
  set split_stats [::tier_split_or2::run]
  _write_split_summary $SUMMARY_OUT $split_mode [dict create \
    candidate_nets [dict get $split_stats candidate_nets] \
    mixed_tier_nets [dict get $split_stats mixed_tier_nets] \
    split_nets [dict get $split_stats split_count] \
    processed_residual [dict get $split_stats processed_residual] \
    skip_reason_counts [dict get $split_stats skip_reason_counts]]
} else {
  set split_mode "disabled_pass_through"
  set action_fh [open $action_report w]
  puts $action_fh "INFO split_net disabled by PIN3D_SPLIT_NET_FLOW=off"
  close $action_fh
  _write_split_summary $SUMMARY_OUT $split_mode [dict create \
    candidate_nets 0 \
    mixed_tier_nets 0 \
    split_nets 0 \
    processed_residual 0]
}

set after_stats [extract_cross_tier_net_stats $after_report]
report_cross_tier_transition $cross_tier_summary_report $before_report $after_report -label "split_net"
puts "INFO(OR): split_net_mode=$split_mode PIN3D_SPLIT_NET_FLOW=[pin3d_split_net_flow_mode]"
puts "INFO(OR): split before cross-tier=[dict get $before_stats cross_tier_all] after=[dict get $after_stats cross_tier_all]"

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_image 1 \
  -write_manifest 1

exit
