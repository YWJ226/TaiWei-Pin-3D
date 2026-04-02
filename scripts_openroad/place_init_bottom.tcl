# ============================================================
# place_init_bottom.tcl
# Run the bottom-side placement initialization pass.
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
set stage_name "place-init-bottom"
# Inputs : ${DESIGN_NAME}_3D.tmp.def / ${DESIGN_NAME}_3D.tmp.v / 2_floorplan.sdc
# Outputs: ${DESIGN_NAME}_3D.tmp.def / ${DESIGN_NAME}_3D.tmp.v / 2_floorplan.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting place init bottom"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set before_report [file join $LOG_DIR "place_init_bottom.before.nets"]
set after_report [file join $LOG_DIR "place_init_bottom.after.nets"]
set summary_report [file join $LOG_DIR "place_init_bottom.cross_tier.summary.rpt"]
apply_tier_policy bottom -fixlib 1 -allow_net all
set place_density [calculate_placement_density]
report_cross_tier_snapshot $before_report -label "place_init_bottom before"

# mark_insts_by_master "*upper*" FIRM

puts "Running global placement with density: $place_density"
set global_placement_args ""
log_cmd global_placement -density $place_density \
        -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
        -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
        {*}$global_placement_args
report_cross_tier_transition $summary_report $before_report $after_report -label "place_init_bottom"

# mark_insts_by_master "*upper*" PLACED

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_image 1 \
  -write_manifest 1

exit
