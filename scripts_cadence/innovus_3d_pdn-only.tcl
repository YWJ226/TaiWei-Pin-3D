# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# innovus_3d_pdn-only.tcl
# Build PDN on top of the macro-aware 3D floorplan.
# ==========================================
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl

set LOG_DIR      [_get LOG_DIR]
set RESULTS_DIR  [_get RESULTS_DIR]
set REPORTS_DIR  [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]

set DEF_IN [file join $RESULTS_DIR "2_5_place_macro_bottom.def"]
set V_IN   [file join $RESULTS_DIR "2_5_place_macro_bottom.v"]
set sdc    [file join $RESULTS_DIR "1_synth.sdc"]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

setMultiCpuUsage -localCpu [_get NUM_CORES 16]

set init_lef_file            $lefs
set init_mmmc_file           ""
set init_design_settop       1
set init_top_cell            $DESIGN
set init_verilog             $V_IN
set init_design_netlisttype  "Verilog"

init_design -setup {WC_VIEW} -hold {BC_VIEW}
_common_setup

defIn $DEF_IN

source $::env(PLATFORM_DIR)/util/pdn_config.tcl
# source $::env(CADENCE_SCRIPTS_DIR)/pdn_flow.tcl

fit
dumpToGIF [file join $LOG_DIR "2_6_floorplan_pdn.png"]
defOut -floorplan [file join $RESULTS_DIR "2_6_floorplan_pdn.def"]
saveNetlist [file join $RESULTS_DIR "2_6_floorplan_pdn.v"]

puts "INFO: 3D PDN-only stage done."
exit