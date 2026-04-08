#################################################################
# pdn_config_upper.tcl
# Upper-tier PDN only
#################################################################

puts "INFO: pdn_config_upper Start upper-tier PDN..."
source $::env(CADENCE_SCRIPTS_DIR)/place_macro_util.tcl

# --------------------------
# Upper mesh geometry
# --------------------------
set W_M4m  0.84
set P_M4m  20.16
set S_M4m  0.56
set O_M4m  2.00

set W_M7m  2.40
set P_M7m  40.00
set S_M7m  1.60
set O_M7m  2.00

# --------------------------
# Tier instance query
# --------------------------
proc get_upper_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_upper" -p2]
  if {[llength $inst_ptrs] == 0} { return "" }
  return [dbGet $inst_ptrs.name]
}

# --------------------------
# Build upper-tier PDN
# --------------------------
proc build_upper_pdn {} {
  set inst_list [get_upper_tier_insts]

  puts "INFO: pdn_config_upper TOP tier inst count = [llength $inst_list]"
  if {[llength $inst_list] == 0} {
    puts "WARN: pdn_config_upper No upper-tier instances found."
    return
  }

  foreach inst $inst_list {
    globalNetConnect TOP_VDD -type pgpin -pin VDD -inst $inst -override
    globalNetConnect TOP_VSS -type pgpin -pin VSS -inst $inst -override
  }
  globalNetConnect TOP_VDD -type tiehi -all -override
  globalNetConnect TOP_VSS -type tielo -all -override

  sroute -nets {TOP_VDD TOP_VSS} \
         -connect {corePin} \
         -corePinLayer {M1_m} \
         -corePinTarget {firstAfterRowEnd}

  # Mirrored stack:
  # mesh_v (M4_m) connects up to rails (M1_m)
  setAddStripeMode -stacked_via_top_layer    M1_m
  setAddStripeMode -stacked_via_bottom_layer M4_m

  addStripe -layer M4_m \
            -direction vertical \
            -nets {TOP_VDD TOP_VSS} \
            -width $::W_M4m \
            -spacing $::S_M4m \
            -start_offset $::O_M4m \
            -set_to_set_distance $::P_M4m

  # mesh_h (M7_m) connects up to mesh_v (M4_m)
  setAddStripeMode -stacked_via_top_layer    M4_m
  setAddStripeMode -stacked_via_bottom_layer M7_m

  addStripe -layer M7_m \
            -direction horizontal \
            -nets {TOP_VDD TOP_VSS} \
            -width $::W_M7m \
            -spacing $::S_M7m \
            -start_offset $::O_M7m \
            -set_to_set_distance $::P_M7m

  puts "INFO: pdn_config_upper Upper-tier PDN finished."
}

# --------------------------
# Top-level PDN flow
# --------------------------
# 1) Unplace core cells only. Keep macro instances fixed.
lassign [pmu::_get_halos upper] halo_x halo_y
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

# 3) Build upper-tier PDN
build_upper_pdn

puts "INFO: pdn_config_upper Finished upper-tier PDN."
