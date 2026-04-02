# ============================================================
# handoff_copy_gp2lg.tcl
# Copy the staged tmp handoff into the legalize handoff.
# ============================================================

# Core setup
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "gp2lg"
# Inputs : ${DESIGN_NAME}_3D.tmp.def / ${DESIGN_NAME}_3D.tmp.v / 2_floorplan.sdc
# Outputs: ${DESIGN_NAME}_3D.lg.def / ${DESIGN_NAME}_3D.lg.v / 2_floorplan.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
file copy -force $DEF_IN $DEF_OUT
file copy -force $V_IN $V_OUT
handoff_copy_if_needed $SDC_IN $SDC_OUT
handoff_write_manifest $stage_paths
exit
