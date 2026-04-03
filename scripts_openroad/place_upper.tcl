# ============================================================
# place_upper.tcl
# Run the upper-side preCTS placement optimization loop.
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
set stage_name "place-upper"
# Inputs : ${DESIGN_NAME}_3D.tmp.def / ${DESIGN_NAME}_3D.tmp.v / 2_floorplan.sdc
# Outputs: ${DESIGN_NAME}_3D.tmp.def / ${DESIGN_NAME}_3D.tmp.v / 2_floorplan.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting place upper"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set before_report [file join $LOG_DIR "place_upper.before.nets"]
set after_report [file join $LOG_DIR "place_upper.after.nets"]
set summary_report [file join $LOG_DIR "place_upper.cross_tier.summary.rpt"]
set mixed_before_report [file join $LOG_DIR "place_upper.mixed_fanout.before.nets"]
set mixed_after_report [file join $LOG_DIR "place_upper.mixed_fanout.after.nets"]
set mixed_summary_report [file join $LOG_DIR "place_upper.mixed_fanout.summary.rpt"]
set split_before_report [file join $LOG_DIR "place_upper.split.before.rpt"]
set split_after_report [file join $LOG_DIR "place_upper.split.after.rpt"]
set split_summary_report [file join $LOG_DIR "place_upper.split.summary.rpt"]
set attribution_report [file join $LOG_DIR "place_upper.cross_tier.delta.rpt"]
write_verilog [file join $RESULTS_DIR "place_upper.before.v"]
set place_density [calculate_placement_density]
# mark_insts_by_master "*bottom*" FIRM
# puts "Marked bottom instances as FIRM"

apply_tier_policy upper -fixlib 1 -allow_net upper-only
fastroute_setup
report_cross_tier_snapshot $before_report -label "place_upper before"
report_mixed_fanout_snapshot $mixed_before_report -label "place_upper before"
report_split_structure_snapshot $split_before_report -label "place_upper before"

set global_placement_args "-routability_driven -timing_driven"
log_cmd global_placement -density $place_density \
    -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
    -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
    {*}$global_placement_args
pin3d_metrics_invalidate_cache
report_cross_tier_transition $summary_report $before_report $after_report -label "place_upper"
report_mixed_fanout_transition $mixed_summary_report $mixed_before_report $mixed_after_report -label "place_upper"
report_split_structure_transition $split_summary_report $split_before_report $split_after_report -label "place_upper"
report_cross_tier_delta_attribution $attribution_report $before_report $after_report -label "place_upper"

# mark_insts_by_master "*bottom*" PLACED
# puts "Marked bottom instances as PLACED"
write_verilog [file join $RESULTS_DIR "place_upper.after.v"]
handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_image 1 \
  -write_manifest 1

estimate_parasitics -placement
source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 3 "global place_upper" false false

exit
