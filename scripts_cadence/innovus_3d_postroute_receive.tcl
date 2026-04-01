# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_postroute_receive.tcl
# Receive-tier postRoute ECO stage.
# ============================================================

# Core setup
source $::env(CADENCE_SCRIPTS_DIR)/route_stage_common.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "postroute-receive"
# Inputs : 5_0_route.def / 5_0_route.v / 5_0_route.sdc / ${DESIGN}_route_only.enc.dat
# Outputs: 5_1_postroute_receive.def / 5_1_postroute_receive.v / 5_1_postroute_receive.sdc
set stage_paths [route_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
source $::env(CADENCE_SCRIPTS_DIR)/cts_stage_common.tcl
handoff_log_paths $stage_paths

set requested_allow_net [cts_receive_requested_allow_net]
set effective_allow_net [cts_receive_allow_net]
_report_allow_net_resolution "postroute-receive" $requested_allow_net $effective_allow_net
puts "INFO: Running staged route stage '$stage_name' (active=[cts_receive_tier], requested_allow_net=[_format_allow_net_class $requested_allow_net], effective_allow_net=[_format_allow_net_class $effective_allow_net])."

route_init_design_from_paths $stage_paths
route_apply_common_layer_setup
route_apply_router_setup
cts_apply_common_ccopt_setup

extract_cross_tier_nets [file join $LOG_DIR "5_1_postroute_receive.before.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_1_postroute_receive.clock.before.nets"] -clock_only 1

set fixed_tier [cts_owner_tier]
set active_tier [cts_receive_tier]
set_tier_placement_status $fixed_tier fixed
apply_tier_policy $active_tier -fixlib 1 -allow_net $effective_allow_net
optDesign -postRoute -incr -outDir $REPORTS_DIR -prefix postroute_receive
set_tier_placement_status $fixed_tier placed

extract_cross_tier_nets [file join $LOG_DIR "5_1_postroute_receive.after.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_1_postroute_receive.clock.after.nets"] -clock_only 1
route_write_stage_outputs $stage_paths

puts "INFO: Completed staged route stage '$stage_name'."
exit
