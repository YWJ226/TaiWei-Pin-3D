# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_postroute_owner.tcl
# Owner-tier postRoute ECO stage.
# ============================================================

source $::env(CADENCE_SCRIPTS_DIR)/route_stage_common.tcl

set stage_name "postroute-owner"
set stage_paths [route_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR]
set sdc [dict get $stage_paths sdc_in]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
source $::env(CADENCE_SCRIPTS_DIR)/cts_stage_common.tcl

puts "INFO: Running staged route stage '$stage_name' (active=[cts_owner_tier], allow_net=[cts_owner_allow_net])."

route_init_design_from_paths $stage_paths
route_apply_common_layer_setup
cts_apply_common_ccopt_setup
route_apply_router_setup

extract_cross_tier_nets [file join $LOG_DIR "5_2_postroute_owner.before.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_2_postroute_owner.clock.before.nets"] -clock_only 1

set fixed_tier [cts_receive_tier]
set active_tier [cts_owner_tier]
set_tier_placement_status $fixed_tier fixed
apply_tier_policy $active_tier -fixlib 1 -allow_net [cts_owner_allow_net]
optDesign -postRoute -incr -outDir $REPORTS_DIR -prefix postroute_owner
set_tier_placement_status $fixed_tier placed

extract_cross_tier_nets [file join $LOG_DIR "5_2_postroute_owner.after.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_2_postroute_owner.clock.after.nets"] -clock_only 1
route_write_stage_outputs $stage_paths

puts "INFO: Completed staged route stage '$stage_name'."
exit
