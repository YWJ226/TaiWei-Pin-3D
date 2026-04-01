# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# innovus_3d_io_place.tcl
# Place IO pins on top of the existing 3D floorplan.
# ==========================================

# Core setup
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "io-place"
# Inputs : 2_3_floorplan_3d.def / 2_3_floorplan_3d.v / 1_synth.sdc
# Outputs: 2_4_floorplan_io.def / 2_4_floorplan_io.v / 1_synth.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
handoff_log_paths $stage_paths

set init_pwr_net {BOT_VDD TOP_VDD}
set init_gnd_net {BOT_VSS TOP_VSS}

handoff_init_design_from_paths $stage_paths

source $::env(CADENCE_SCRIPTS_DIR)/place_pin.tcl

handoff_write_stage_outputs $stage_paths \
  -def_args {-floorplan} \
  -copy_sdc 0 \
  -save_design 0 \
  -write_png 1 \
  -write_manifest 1

puts "INFO: 3D IO placement done."
exit
