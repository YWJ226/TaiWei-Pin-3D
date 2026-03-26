# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# innovus_3d_pdn-only-upper.tcl
# Build upper-tier PDN only.
# ==========================================
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl

set LOG_DIR      [_get LOG_DIR]
set RESULTS_DIR  [_get RESULTS_DIR]
set REPORTS_DIR  [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]

set DEF_IN [file join $RESULTS_DIR "2_6_floorplan_pdn_bottom.def"]
set V_IN   [file join $RESULTS_DIR "2_6_floorplan_pdn_bottom.v"]
set sdc    [file join $RESULTS_DIR "1_synth.sdc"]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

set init_lef_file            $lefs
set init_mmmc_file           ""
set init_design_settop       1
set init_top_cell            $DESIGN
set init_verilog             $V_IN
set init_design_netlisttype  "Verilog"

init_design -setup {WC_VIEW} -hold {BC_VIEW}
_common_setup
defIn $DEF_IN

if {[info exists ::env(UPPER_SITE)] && $::env(UPPER_SITE) ne ""} {
    rebuild_rows_for_site $::env(UPPER_SITE) upper
} else {
    rebuild_rows_for_site $::env(PLACE_SITE) upper
}

source $::env(PLATFORM_DIR)/util/pdn_config_upper.tcl

fit
dumpToGIF [file join $LOG_DIR "2_6_floorplan_pdn_upper.png"]
defOut -floorplan [file join $RESULTS_DIR "2_6_floorplan_pdn.def"]
saveNetlist [file join $RESULTS_DIR "2_6_floorplan_pdn.v"]

puts "INFO: Upper-tier PDN stage done."
exit