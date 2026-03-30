# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# innovus_3d_floorplan.tcl
# Build the 3D floorplan only.
# ==========================================
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl

set LOG_DIR      [_get LOG_DIR]
set RESULTS_DIR  [_get RESULTS_DIR]
set REPORTS_DIR  [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]

set V_IN [file join $RESULTS_DIR "${DESIGN}_3D.fp.v"]
set sdc  [file join $RESULTS_DIR "1_synth.sdc"]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

set init_lef_file            $lefs
set init_mmmc_file           ""
set init_design_settop       1
set init_top_cell            $DESIGN
set init_verilog             $V_IN
set init_design_netlisttype  "Verilog"

init_design -setup {WC_VIEW} -hold {BC_VIEW}
_common_setup

set CORE_UTIL    [_get CORE_UTILIZATION 60]
set ASPECT_RATIO [_get CORE_ASPECT_RATIO 1.0]
set CORE_MARGIN  [_get CORE_MARGIN 0.2]
set PLACE_SITE   [_get PLACE_SITE ""]
set CREATE_OBS_STAGE [_get CREATE_OBS_STAGE ""]

set U_target [expr {double($CORE_UTIL) / 100.0}]
set mL $CORE_MARGIN
set mR $CORE_MARGIN
set mT $CORE_MARGIN
set mB $CORE_MARGIN

source $::env(CADENCE_SCRIPTS_DIR)/extract_report.tcl
set cross_tier_net_estimate [extract_cross_tier_nets [file join $LOG_DIR "2_3_floorplan_3d.nets"]]
puts "INFO: Cross-tier net estimate at floorplan stage = $cross_tier_net_estimate"

source $::env(CADENCE_SCRIPTS_DIR)/floorplan_utils.tcl
lassign [tier::core_wh_for_max_tier_util $U_target $ASPECT_RATIO] CORE_W CORE_H A_up A_bot A_max

puts "INFO: Tier areas: upper=$A_up bottom=$A_bot max=$A_max"
puts "INFO: Core size: W=$CORE_W H=$CORE_H"
set base_core_area [expr {$CORE_W * $CORE_H}]

source $::env(CADENCE_SCRIPTS_DIR)/innovus_hb_layer_obs.tcl
    if {$CREATE_OBS_STAGE == "FLOORPLAN"} {
    lassign [hb_required_core_wh \
        -estimated_hbt_count $cross_tier_net_estimate \
        -aspect_ratio $ASPECT_RATIO \
        -origin_x $mL \
        -origin_y $mB] hbt_required_core_w hbt_required_core_h hbt_required_core_area
    puts "INFO: HBT-required core area = $hbt_required_core_area"
    if {$hbt_required_core_area > $base_core_area} {
        set CORE_W $hbt_required_core_w
        set CORE_H $hbt_required_core_h
        puts "INFO: Expand core size for HBT capacity before floorplan. old_area=$base_core_area new_area=$hbt_required_core_area"
        puts "INFO: Expanded core size: W=$CORE_W H=$CORE_H"
    }
}

puts "INFO: Final floorplan core size after one-shot HBT sizing: W=$CORE_W H=$CORE_H"
floorPlan -s [list $CORE_W $CORE_H $mL $mB $mR $mT] -siteOnly $PLACE_SITE -adjustToSite

deleteTrack
generateTracks

if {$CREATE_OBS_STAGE == "FLOORPLAN"} {
    puts "INFO: Create HBT allow window in stage FLOORPLAN"
    create_hb_layer_obs -estimated_hbt_count $cross_tier_net_estimate
}
fit
dumpToGIF [file join $LOG_DIR "2_3_floorplan_3d.png"]
defOut -floorplan [file join $RESULTS_DIR "2_3_floorplan_3d.def"]
saveNetlist [file join $RESULTS_DIR "2_3_floorplan_3d.v"]

puts "INFO: 3D floorplan done."
exit
