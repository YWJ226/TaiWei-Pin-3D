# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_cts_finalize.tcl
# Final CTS handoff/report stage for staged 3D CTS.
# ============================================================

# Core setup
source $::env(CADENCE_SCRIPTS_DIR)/cts_stage_common.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "finalize"
# Inputs : 4_1_cts_receive_opt.def / 4_1_cts_receive_opt.v / 4_1_cts_receive_opt.sdc
# Outputs: 4_3_cts_finalize.def / 4_3_cts_finalize.v / 4_3_cts_finalize.sdc / 4_cts.def / 4_cts.v / 4_cts.sdc
set stage_paths [cts_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
handoff_log_paths $stage_paths

puts "INFO: Running staged 3D CTS stage '$stage_name' (owner=[cts_owner_tier], receive=[cts_receive_tier])."

cts_init_design_from_paths $stage_paths
cts_apply_common_ccopt_setup

extract_cross_tier_nets [file join $LOG_DIR "cts_finalize.nets"] -clock_only 1
cts_write_stage_outputs $stage_paths

puts "INFO: Completed staged 3D CTS stage '$stage_name'."
exit
