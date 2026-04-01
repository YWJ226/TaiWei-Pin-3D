# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_split_net.tcl
# Standalone post-IO mixed-tier net split stage.
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
set stage_name "split-net"
# Inputs : 2_4_floorplan_io.def / 2_4_floorplan_io.v / 1_synth.sdc
# Outputs: 2_4_floorplan_io.def / 2_4_floorplan_io.v / 1_synth.sdc / ${DESIGN}_3d_after_split_net.enc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
handoff_log_paths $stage_paths

handoff_init_design_from_paths $stage_paths

source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
source $::env(CADENCE_SCRIPTS_DIR)/split_net.tcl

extract_cross_tier_nets [file join $LOG_DIR "split_net.before.nets"]

namespace eval ::mixed_tier_split {
  variable CFG
  set CFG(report_file) [file join $::LOG_DIR "split_net.summary.rpt"]
  set CFG(action_file) [file join $::LOG_DIR "split_net.actions.rpt"]
  set CFG(dry_run) 0
  set CFG(run_eco_place) 0
  set CFG(verify_processed) 1
}

set split_summary [file join $LOG_DIR "split_net.summary.rpt"]
set split_actions [file join $LOG_DIR "split_net.actions.rpt"]
set split_mode "enabled"
if {[pin3d_split_net_flow_enabled]} {
  ::mixed_tier_split::run
} else {
  set split_mode "disabled_pass_through"
  set action_fh [open $split_actions w]
  puts $action_fh "# Mixed-tier net split actions"
  puts $action_fh "# split_net_mode=disabled_pass_through"
  puts $action_fh "INFO split_net disabled by PIN3D_SPLIT_NET_FLOW=off"
  close $action_fh

  set summary_fh [open $split_summary w]
  puts $summary_fh "mode disabled_pass_through"
  puts $summary_fh "candidate_nets 0"
  puts $summary_fh "mixed_tier_nets 0"
  puts $summary_fh "split_nets 0"
  puts $summary_fh "skipped_nets 0"
  puts $summary_fh "processed_residual 0"
  puts $summary_fh "io_upper 0"
  puts $summary_fh "io_bottom 0"
  puts $summary_fh ""
  puts $summary_fh "skip_reasons"
  close $summary_fh
}

puts "INFO: split_net_mode=$split_mode PIN3D_SPLIT_NET_FLOW=[pin3d_split_net_flow_mode]"

extract_cross_tier_nets [file join $LOG_DIR "split_net.after.nets"]

set split_enabled [pin3d_split_net_flow_enabled]
handoff_write_stage_outputs $stage_paths \
  -def_args {-floorplan} \
  -write_def $split_enabled \
  -write_v $split_enabled \
  -copy_sdc 0 \
  -save_design 1 \
  -write_png 1 \
  -write_manifest 1 \
  -extra_manifest [list split_net_mode $split_mode]

puts "INFO: Post-IO split-net stage done."
puts "INFO:   DEF -> [handoff_get $stage_paths def_out]"
puts "INFO:   Verilog -> [handoff_get $stage_paths v_out]"
exit
