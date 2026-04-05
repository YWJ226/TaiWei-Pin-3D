# ============================================================
# innovus_3d_route_legacy.tcl
# Legacy route + postRoute baseline kept for robustness comparison.
# ============================================================

# Core setup
source $::env(CADENCE_SCRIPTS_DIR)/route_stage_common.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "route-legacy"
# Inputs : 4_cts.def / 4_cts.v / 4_cts.sdc
# Outputs: 5_route.def / 5_route.v / 5_route.sdc / ${DESIGN}_postRoute.enc.dat
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
handoff_log_paths $stage_paths

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

extract_cross_tier_nets [file join $LOG_DIR "5_route.before.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_route.clock.before.nets"] -clock_only 1
routeDesign
extract_cross_tier_nets [file join $LOG_DIR "5_route.after.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_route.clock.after.nets"] -clock_only 1

set_tier_placement_status bottom fixed
set_tier_placement_status upper fixed

source $::env(CADENCE_SCRIPTS_DIR)/cts_stage_common.tcl
set cts_policy_stage "owner-tree"
set requested_allow_net [cts_owner_requested_allow_net]
set effective_allow_net [cts_owner_allow_net]
_report_allow_net_resolution "route-legacy" $requested_allow_net $effective_allow_net
puts "INFO: Running optDesign -postRoute (owner=[cts_owner_tier], receive=[cts_receive_tier], requested_allow_net=[_format_allow_net_class $requested_allow_net], effective_allow_net=[_format_allow_net_class $effective_allow_net])."
apply_tier_policy [cts_owner_tier] -fixlib 1 -allow_net $effective_allow_net
optDesign -postRoute -outDir $REPORTS_DIR -prefix route_legacy

extract_cross_tier_nets [file join $LOG_DIR "5_route.after.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_route.clock.after.nets"] -clock_only 1

handoff_write_stage_outputs $stage_paths \
  -def_args {-netlist -floorplan -routing} \
  -copy_sdc 1 \
  -save_design 1 \
  -write_png 1 \
  -write_manifest 1 \
  -extra_manifest [list \
    owner_tier [cts_owner_tier] \
    receive_tier [cts_receive_tier]]
puts "INFO: Legacy route done. DEF: [handoff_get $stage_paths def_out]  V: [handoff_get $stage_paths v_out]  SDC: [handoff_get $stage_paths sdc_out]  ENC: [handoff_get $stage_paths enc_out]"
exit
