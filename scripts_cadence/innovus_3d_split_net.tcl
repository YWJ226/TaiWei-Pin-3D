# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_split_net.tcl
# Standalone post-IO mixed-tier net split stage.
# Reads:
#   2_4_floorplan_io.def / 2_4_floorplan_io.v
# Writes:
#   2_4_floorplan_split.def / 2_4_floorplan_split.v
# ============================================================

source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl

set LOG_DIR      [_get LOG_DIR]
set RESULTS_DIR  [_get RESULTS_DIR]
set REPORTS_DIR  [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]

set DEF_IN  [file join $RESULTS_DIR "2_4_floorplan_io.def"]
set V_IN    [file join $RESULTS_DIR "2_4_floorplan_io.v"]
set SDC_IN  [file join $RESULTS_DIR "1_synth.sdc"]
set sdc     $SDC_IN

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog $V_IN
set init_design_netlisttype "Verilog"

init_design -setup {WC_VIEW} -hold {BC_VIEW}
_common_setup
defIn $DEF_IN

source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
source $::env(CADENCE_SCRIPTS_DIR)/split_net.tcl

extract_cross_tier_nets [file join $LOG_DIR "split_net.before.nets"]

namespace eval ::mixed_tier_split {
  variable CFG
  set CFG(report_file) [file join $::LOG_DIR "split_net.summary.rpt"]
  set CFG(action_file) [file join $::LOG_DIR "split_net.actions.rpt"]
  set CFG(dry_run) 0
  set CFG(run_eco_place) 0
  set CFG(verify_processed) 1
}

::mixed_tier_split::run

extract_cross_tier_nets [file join $LOG_DIR "split_net.after.nets"]

set DEF_OUT [file join $RESULTS_DIR "2_4_floorplan_split.def"]
set V_OUT   [file join $RESULTS_DIR "2_4_floorplan_split.v"]
defOut -floorplan $DEF_OUT
saveNetlist $V_OUT
saveDesign [file join $OBJECTS_DIR "${DESIGN}_3d_after_split_net.enc"]
fit
dumpToGIF [file join $LOG_DIR "2_4_floorplan_split.png"]

puts "INFO: Post-IO split-net stage done."
puts "INFO:   DEF -> $DEF_OUT"
puts "INFO:   Verilog -> $V_OUT"
exit
