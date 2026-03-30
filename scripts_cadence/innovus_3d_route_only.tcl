# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_route_only.tcl
# Pure route stage for staged route/postRoute flow.
# The Makefile launches this script with the route-only LEF/COVER view.
# ============================================================

source $::env(CADENCE_SCRIPTS_DIR)/route_stage_common.tcl

set stage_name "route-only"
set stage_paths [route_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR]
set sdc [dict get $stage_paths sdc_in]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
source $::env(CADENCE_SCRIPTS_DIR)/cts_stage_common.tcl

puts "INFO: Running staged route stage '$stage_name'."

route_init_design_from_paths $stage_paths
route_apply_common_layer_setup
route_apply_router_setup

set create_obs_stage [_get CREATE_OBS_STAGE ""]
if {$create_obs_stage eq "ROUTE"} {
  puts "INFO: Create HBT allow window in stage ROUTE"
  source $::env(CADENCE_SCRIPTS_DIR)/innovus_hb_layer_obs.tcl
  catch { create_hb_layer_obs }
}

extract_cross_tier_nets [file join $LOG_DIR "5_0_route.before.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_0_route.clock.before.nets"] -clock_only 1
routeDesign
extract_cross_tier_nets [file join $LOG_DIR "5_0_route.after.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_0_route.clock.after.nets"] -clock_only 1
route_write_stage_outputs $stage_paths

puts "INFO: Completed staged route stage '$stage_name'."
exit
