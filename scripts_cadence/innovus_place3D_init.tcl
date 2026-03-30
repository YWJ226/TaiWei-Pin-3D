# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ===============================
# innovus_place3D_init.tcl — 3D place init with stable modes
# ===============================
# Source utility and setup scripts
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/place_common.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl

# Get directory paths from the environment/setup
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]

# Define input file paths based on the results directory
set FPDEF      [file join $RESULTS_DIR "2_floorplan.def"]
set FPVERILOG  [file join $RESULTS_DIR "2_floorplan.v"]
set sdc        [file join $RESULTS_DIR "1_synth.sdc"]

# Source the multi-mode multi-corner (MMMC) setup script
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

# Set up initial design parameters
set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog $FPVERILOG
set init_design_netlisttype "Verilog"

init_design -setup {WC_VIEW} -hold {BC_VIEW}
_common_setup

# Read in the floorplan DEF file
defIn $FPDEF

set_tier_placement_status upper fixed
saveNetlist [file join $RESULTS_DIR "${DESIGN}_3D.init.before.v"]
extract_cross_tier_nets [file join $LOG_DIR "place_3d_init.before.nets"]
apply_tier_policy bottom -fixlib 1 -allow_net bottom-only
pc::setup_basic

place_design

set_tier_placement_status upper placed
extract_cross_tier_nets [file join $LOG_DIR "place_3d_init.after.nets"]
saveNetlist [file join $RESULTS_DIR "${DESIGN}_3D.init.after.v"]

# Define output file paths for the placed design
set GPDEFOUT [file join $RESULTS_DIR "${DESIGN}_3D.tmp.def"]
set GPVOUT   [file join $RESULTS_DIR "${DESIGN}_3D.tmp.v"]
# Write out the placed DEF file
defOut -floorplan $GPDEFOUT
# Save the netlist
saveNetlist $GPVOUT
# Fit the design view to the window
fit
# Dump a screenshot of the layout
dumpToGIF $LOG_DIR/3_place_init.png
# Print completion message
puts "INFO: 3D bottom tier bootstrap place init done. DEF: $GPDEFOUT  V: $GPVOUT"

# Exit the tool
exit
