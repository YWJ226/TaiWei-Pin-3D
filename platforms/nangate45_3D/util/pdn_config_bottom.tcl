#################################################################
# pdn_config_bottom.tcl
# Bottom-tier PDN only
#################################################################

puts "INFO: pdn_config_bottom Start bottom-tier PDN..."
source $::env(CADENCE_SCRIPTS_DIR)/place_macro_util.tcl

# --------------------------
# Bottom mesh geometry
# --------------------------
set W_M4   0.84
set P_M4   20.16
set S_M4   0.56
set O_M4   2.00

set W_M7   2.40
set P_M7   40.00
set S_M7   1.60
set O_M7   2.00

# --------------------------
# Tier instance query
# --------------------------
proc get_bottom_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_bottom" -p2]
  if {[llength $inst_ptrs] == 0} { return "" }
  return [dbGet $inst_ptrs.name]
}

# --------------------------
# Build bottom-tier PDN
# --------------------------
proc build_bottom_pdn {} {
  set inst_list [get_bottom_tier_insts]

  puts "INFO: pdn_config_bottom BOT tier inst count = [llength $inst_list]"
  if {[llength $inst_list] == 0} {
    puts "WARN: pdn_config_bottom No bottom-tier instances found."
    return
  }

  foreach inst $inst_list {
    globalNetConnect BOT_VDD -type pgpin -pin VDD -inst $inst -override
    globalNetConnect BOT_VSS -type pgpin -pin VSS -inst $inst -override
  }
  globalNetConnect BOT_VDD -type tiehi -all -override
  globalNetConnect BOT_VSS -type tielo -all -override

  sroute -nets {BOT_VDD BOT_VSS} \
         -connect {corePin} \
         -corePinLayer {M1} \
         -corePinTarget {firstAfterRowEnd}

  setAddStripeMode -stacked_via_top_layer    M4
  setAddStripeMode -stacked_via_bottom_layer M1

  addStripe -layer M4 \
            -direction vertical \
            -nets {BOT_VDD BOT_VSS} \
            -width $::W_M4 \
            -spacing $::S_M4 \
            -start_offset $::O_M4 \
            -set_to_set_distance $::P_M4

  setAddStripeMode -stacked_via_top_layer    M7
  setAddStripeMode -stacked_via_bottom_layer M4

  addStripe -layer M7 \
            -direction horizontal \
            -nets {BOT_VDD BOT_VSS} \
            -width $::W_M7 \
            -spacing $::S_M7 \
            -start_offset $::O_M7 \
            -set_to_set_distance $::P_M7

  puts "INFO: pdn_config_bottom Bottom-tier PDN finished."
}

# --------------------------
# Top-level PDN flow
# --------------------------
# 1) Unplace core cells only. Keep macro instances fixed.
lassign [pmu::_get_halos bottom] halo_x halo_y
set minCh [expr {$halo_x > $halo_y ? $halo_x : $halo_y}]
set core_insts [dbGet top.insts.cell.subClass core -p2]
if {[llength $core_insts] > 0} {
  dbSet $core_insts.pStatus unplaced
}
if {$minCh > 0} {
  finishFloorplan -fillPlaceBlockage hard $minCh
  cutRow
  finishFloorplan -fillPlaceBlockage hard $minCh
  set fp_blk [dbGet top.fPlan.pBlkgs.name finishfp_place_blkg_* -p1]
  if {[llength $fp_blk] > 0} {
    deselectAll
    select_obj $fp_blk
    deleteSelectedFromFPlan
    deselectAll
  }
}

# 2) Common stripe configuration
setAddStripeMode -orthogonal_only true
setAddStripeMode -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

clearGlobalNets

# 3) Build bottom-tier PDN
build_bottom_pdn

puts "INFO: pdn_config_bottom Finished bottom-tier PDN."
