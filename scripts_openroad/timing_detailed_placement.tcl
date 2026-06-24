# ============================================================
# timing_detailed_placement.tcl
# Run the timing placement optimization loop.
# ============================================================

# debug options
# puts "\n[string repeat "*" 40]"
# puts "DEBUG MODE: PID is [pid]"
# puts "Wait for VS Code to attach... (20s)"
# puts "[string repeat "*" 40]\n"
# after 10000 ;# 暂停 20 秒
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
set stage_name "timing-detailed-placement"
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting timing detailed place"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set before_report [file join $LOG_DIR "tdp.before.nets"]
set after_report [file join $LOG_DIR "tdp.after.nets"]
set summary_report [file join $LOG_DIR "tdp.cross_tier.summary.rpt"]
set mixed_before_report [file join $LOG_DIR "tdp.mixed_fanout.before.nets"]
set mixed_after_report [file join $LOG_DIR "tdp.mixed_fanout.after.nets"]
set mixed_summary_report [file join $LOG_DIR "tdp.mixed_fanout.summary.rpt"]
set split_before_report [file join $LOG_DIR "tdp.split.before.rpt"]
set split_after_report [file join $LOG_DIR "tdp.split.after.rpt"]
set split_summary_report [file join $LOG_DIR "tdp.split.summary.rpt"]
set attribution_report [file join $LOG_DIR "tdp.cross_tier.delta.rpt"]
write_verilog [file join $RESULTS_DIR "tdp.before.v"]

#set place_density [calculate_placement_density]
# mark_insts_by_master "*upper*" FIRM
# puts "Marked upper instances as FIRM"

report_cross_tier_snapshot $before_report -label "tdp before"
report_mixed_fanout_snapshot $mixed_before_report -label "tdp before"
report_split_structure_snapshot $split_before_report -label "tdp before"

log_cmd timing_detailed_placement -max_displacement {10 10}

pin3d_metrics_invalidate_cache
report_cross_tier_transition $summary_report $before_report $after_report -label "tdp"
report_mixed_fanout_transition $mixed_summary_report $mixed_before_report $mixed_after_report -label "tdp"
report_split_structure_transition $split_summary_report $split_before_report $split_after_report -label "tdp"
report_cross_tier_delta_attribution $attribution_report $before_report $after_report -label "tdp"

# mark_insts_by_master "*upper*" PLACED
# puts "Marked upper instances as PLACED"
write_verilog [file join $RESULTS_DIR "tdp.after.v"]
handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_manifest 1

estimate_parasitics -placement
source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 3 "tdp" false false

exit
