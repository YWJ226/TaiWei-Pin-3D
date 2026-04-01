# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# handoff_copy_gp2lg.tcl
# Copy the temporary placed handoff into the legalize handoff names.
# This stage does not need Innovus. It only records the handoff transition
# through the unified manifest interface.
# ============================================================

# Core setup
source $::env(CADENCE_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "gp2lg"
# Inputs : ${DESIGN}_3D.tmp.def / ${DESIGN}_3D.tmp.v / 2_floorplan.sdc
# Outputs: ${DESIGN}_3D.lg.def / ${DESIGN}_3D.lg.v / 2_floorplan.sdc / handoffs/gp2lg.tcl
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
handoff_require_inputs $stage_paths {def_in v_in sdc_in}

handoff_copy_file_if_exists $DEF_IN $DEF_OUT
handoff_copy_file_if_exists $V_IN $V_OUT
handoff_copy_file_if_exists $SDC_IN $SDC_OUT
handoff_write_manifest $stage_paths -extra_kv [list mode copy_only]

puts "INFO: GP2LG handoff copy done."
puts "INFO:   DEF -> $DEF_OUT"
puts "INFO:   V   -> $V_OUT"
puts "INFO:   SDC -> $SDC_OUT"
exit 0
