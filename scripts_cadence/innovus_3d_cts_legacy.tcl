# ============== Legacy CTS on 3_place.{def,v,sdc} ==============
# This script is kept as an explicit comparison baseline for robustness studies.
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl

set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

set DEF_IN   [file join $RESULTS_DIR "3_place.def"]
set V_IN     [file join $RESULTS_DIR "3_place.v"]
set sdc      [file join $RESULTS_DIR "3_place.sdc"]

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
defIn $DEF_IN

if {[info exists ::env(MAX_ROUTING_LAYER)]} {
  setDesignMode -topRoutingLayer $::env(MAX_ROUTING_LAYER)
}
if {[info exists ::env(MIN_ROUTING_LAYER)]} {
  setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER)
}

set_ccopt_property post_conditioning_enable_routing_eco 1
set_ccopt_property -cts_def_lock_clock_sinks_after_routing true
setOptMode -unfixClkInstForOpt false

set active_tier "bottom"
set fixed_tier "upper"
if {[info exists ::env(CTS_LAYER)] && $::env(CTS_LAYER) ne ""} {
  set active_tier [string tolower $::env(CTS_LAYER)]
  if {$active_tier eq "upper"} {
    set fixed_tier "bottom"
  }
}

extract_cross_tier_nets [file join $LOG_DIR "cts_legacy.before.nets"] -clock_only 1
set_tier_placement_status $fixed_tier fixed
apply_tier_policy $active_tier -fixlib 1

create_ccopt_clock_tree_spec
ccopt_design

set_tier_placement_status $fixed_tier placed
extract_cross_tier_nets [file join $LOG_DIR "cts_legacy.after.nets"] -clock_only 1

set DEF_STAGE_OUT [file join $RESULTS_DIR "4_1_cts.def"]
set V_STAGE_OUT   [file join $RESULTS_DIR "4_1_cts.v"]
set SDC_STAGE_OUT [file join $RESULTS_DIR "4_1_cts.sdc"]
set DEF_OUT       [file join $RESULTS_DIR "4_cts.def"]
set V_OUT         [file join $RESULTS_DIR "4_cts.v"]
set SDC_OUT       [file join $RESULTS_DIR "4_cts.sdc"]

defOut -floorplan -routing $DEF_STAGE_OUT
saveNetlist $V_STAGE_OUT
if {[file exists $sdc]} {
  file copy -force $sdc $SDC_STAGE_OUT
  file copy -force $sdc $SDC_OUT
}
file copy -force $DEF_STAGE_OUT $DEF_OUT
file copy -force $V_STAGE_OUT $V_OUT

fit
dumpToGIF $LOG_DIR/4_1_cts.png
puts "INFO: Legacy CTS done. DEF -> $DEF_OUT  V -> $V_OUT  SDC -> $SDC_OUT"
exit
