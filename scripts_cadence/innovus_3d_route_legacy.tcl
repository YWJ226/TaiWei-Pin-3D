# ============================================================
# innovus_3d_route_legacy.tcl
# Legacy route + postRoute baseline kept for robustness comparison.
# ============================================================
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl

set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

set DEF_IN   [file join $RESULTS_DIR "4_cts.def"]
set V_IN     [file join $RESULTS_DIR "4_cts.v"]
set sdc      [file join $RESULTS_DIR "4_cts.sdc"]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl

setMultiCpuUsage -localCpu [_get NUM_CORES 16]

set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog $V_IN
set init_design_netlisttype "Verilog"
setGenerateViaMode -auto true
init_design -setup {WC_VIEW} -hold {BC_VIEW}
set_power_analysis_mode -leakage_power_view WC_VIEW -dynamic_power_view WC_VIEW
set_interactive_constraint_modes {CON}
setAnalysisMode -reset
setAnalysisMode -analysisType onChipVariation -cppr both
set_interactive_constraint_modes [all_constraint_modes -active]
set_propagated_clock [all_clocks]
set_clock_propagation propagated
defIn $DEF_IN

if {[info exists ::env(MAX_ROUTING_LAYER)]} {
  setDesignMode -topRoutingLayer $::env(MAX_ROUTING_LAYER)
}
if {[info exists ::env(MIN_ROUTING_LAYER)]} {
  setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER)
}

setNanoRouteMode -grouteExpWithTimingDriven false
if {![info exists ::env(DETAILED_ROUTE_END_ITERATION)]} {
  set ::env(DETAILED_ROUTE_END_ITERATION) 20
}
setNanoRouteMode -drouteEndIteration $::env(DETAILED_ROUTE_END_ITERATION)
setNanoRouteMode -drouteVerboseViolationSummary 1
setNanoRouteMode -routeWithSiDriven true
setNanoRouteMode -routeWithTimingDriven true
setNanoRouteMode -routeUseAutoVia true
setNanoRouteMode -routeWithViaInPin "1:1"
setNanoRouteMode -routeWithViaOnlyForStandardCellPin "1:1"
setNanoRouteMode -drouteOnGridOnly "via 1:1"
setNanoRouteMode -drouteAutoStop false
setNanoRouteMode -drouteExpAdvancedMarFix true
setNanoRouteMode -routeExpAdvancedTechnology true

extract_cross_tier_nets [file join $LOG_DIR "5_route.before.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_route.clock.before.nets"] -clock_only 1
routeDesign

set_tier_placement_status bottom fixed
set_tier_placement_status upper fixed
optDesign -postRoute -outDir $REPORTS_DIR -prefix route_legacy

extract_cross_tier_nets [file join $LOG_DIR "5_route.after.nets"]
extract_cross_tier_nets [file join $LOG_DIR "5_route.clock.after.nets"] -clock_only 1

set DEF_OUT  [file join $RESULTS_DIR "5_route.def"]
set V_OUT    [file join $RESULTS_DIR "5_route.v"]
set SDC_OUT  [file join $RESULTS_DIR "5_route.sdc"]
set ENC_OUT  [file join $OBJECTS_DIR  "${DESIGN}_postRoute.enc"]
defOut -netlist -floorplan -routing $DEF_OUT
saveNetlist $V_OUT
if {[file exists $sdc]} {
  file copy -force $sdc $SDC_OUT
}
saveDesign $ENC_OUT
fit
dumpToGIF $LOG_DIR/5_route.png
puts "INFO: Legacy route done. DEF: $DEF_OUT  V: $V_OUT  SDC: $SDC_OUT  ENC: $ENC_OUT"
exit
