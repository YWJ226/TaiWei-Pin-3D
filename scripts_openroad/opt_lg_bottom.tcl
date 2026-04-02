# ============================================================
# opt_lg_bottom.tcl
# Run the bottom-side legalization and detail optimization pass.
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
set stage_name "legalize-bottom"
# Inputs : ${DESIGN_NAME}_3D.lg.def / ${DESIGN_NAME}_3D.lg.v / 2_floorplan.sdc
# Outputs: ${DESIGN_NAME}_3D.lg.def / ${DESIGN_NAME}_3D.lg.v / 3_place.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting bottom optimization and legalization"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set before_report [file join $LOG_DIR "legalize_bottom.before.nets"]
set after_report [file join $LOG_DIR "legalize_bottom.after.nets"]
set summary_report [file join $LOG_DIR "legalize_bottom.cross_tier.summary.rpt"]

# mark_insts_by_master "*upper*" FIRM

apply_tier_policy bottom -fixlib 1 -allow_net bottom-only -protect_split_buffers 0
report_cross_tier_snapshot $before_report -label "legalize_bottom before"

source $::env(OPENROAD_SCRIPTS_DIR)/opt_lg_design.tcl
report_cross_tier_transition $summary_report $before_report $after_report -label "legalize_bottom"

# mark_insts_by_master "*upper*" PLACED

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_image 1 \
  -write_manifest 1

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 3 "detailed place_bottom" true false

exit
