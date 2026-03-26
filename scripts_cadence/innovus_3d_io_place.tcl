# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# innovus_3d_io_place.tcl
# Place IO pins on top of the existing 3D floorplan.
# ==========================================
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl

set LOG_DIR      [_get LOG_DIR]
set RESULTS_DIR  [_get RESULTS_DIR]
set REPORTS_DIR  [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]

set DEF_IN [file join $RESULTS_DIR "2_3_floorplan_3d.def"]
set V_IN   [file join $RESULTS_DIR "2_3_floorplan_3d.v"]
set sdc    [file join $RESULTS_DIR "1_synth.sdc"]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

set init_lef_file            $lefs
set init_mmmc_file           ""
set init_design_settop       1
set init_top_cell            $DESIGN
set init_verilog             $V_IN
set init_design_netlisttype  "Verilog"

set init_pwr_net {BOT_VDD TOP_VDD}
set init_gnd_net {BOT_VSS TOP_VSS}

init_design -setup {WC_VIEW} -hold {BC_VIEW}
_common_setup
defIn $DEF_IN

source $::env(CADENCE_SCRIPTS_DIR)/place_pin.tcl

fit
dumpToGIF [file join $LOG_DIR "2_4_floorplan_io.png"]
defOut -floorplan [file join $RESULTS_DIR "2_4_floorplan_io.def"]
saveNetlist [file join $RESULTS_DIR "2_4_floorplan_io.v"]

puts "INFO: 3D IO placement done."
exit
