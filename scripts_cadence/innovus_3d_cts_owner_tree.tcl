# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_cts_owner_tree.tcl
# Owner-tier tree construction stage for staged 3D CTS.
# ============================================================

# Core setup
source $::env(CADENCE_SCRIPTS_DIR)/cts_stage_common.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "owner-tree"
# Inputs : 3_place.def / 3_place.v / 3_place.sdc
# Outputs: 4_0_cts_owner_tree.def / 4_0_cts_owner_tree.v / 4_0_cts_owner_tree.sdc
set stage_paths [cts_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
handoff_log_paths $stage_paths

set requested_allow_net [cts_owner_requested_allow_net]
set effective_allow_net [cts_owner_allow_net]
_report_allow_net_resolution "cts-owner-tree" $requested_allow_net $effective_allow_net
puts "INFO: Running staged 3D CTS stage '$stage_name' (owner=[cts_owner_tier], receive=[cts_receive_tier], requested_allow_net=[_format_allow_net_class $requested_allow_net], effective_allow_net=[_format_allow_net_class $effective_allow_net])."

cts_init_design_from_paths $stage_paths
cts_apply_common_ccopt_setup
cts_write_wrapper_artifacts $stage_paths

extract_cross_tier_nets [file join $LOG_DIR "cts_owner_tree.before.nets"] -clock_only 1

set fixed_tier [cts_receive_tier]
set active_tier [cts_owner_tier]
set_tier_placement_status $fixed_tier fixed
apply_tier_policy $active_tier -fixlib 1 -allow_net $effective_allow_net

create_ccopt_clock_tree_spec
ccopt_design

set_tier_placement_status $fixed_tier placed
extract_cross_tier_nets [file join $LOG_DIR "cts_owner_tree.after.nets"] -clock_only 1
cts_write_stage_outputs $stage_paths

puts "INFO: Completed staged 3D CTS stage '$stage_name'."
exit
