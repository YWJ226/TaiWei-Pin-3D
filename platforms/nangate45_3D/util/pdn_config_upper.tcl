#################################################################
# pdn_config_simple_upper.tcl
# Minimal 3D PDN for upper tier only
#################################################################

puts "INFO: Start upper-tier PDN..."

# --------------------------
# Basic floorplan channels
# --------------------------
set minCh 5

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
# Common PDN floorplan prep
# --------------------------
proc prepare_pdn_floorplan {min_ch} {
  set core_insts [dbGet top.insts.cell.subClass core -p2]
  if {[llength $core_insts] > 0} {
    dbSet $core_insts.pStatus unplaced
  }
  finishFloorplan -fillPlaceBlockage hard $min_ch
  cutRow
  finishFloorplan -fillPlaceBlockage hard $min_ch

  set fp_blk [dbGet top.fPlan.pBlkgs.name finishfp_place_blkg_* -p1]
  if {[llength $fp_blk] > 0} {
    deselectAll
    select_obj $fp_blk
    deleteSelectedFromFPlan
    deselectAll
  }
}

# --------------------------
# Build upper-tier PDN
# --------------------------
proc build_upper_pdn {} {
  set inst_list [get_upper_tier_insts]

  puts "INFO: TOP inst count = [llength $inst_list]"
  if {[llength $inst_list] == 0} {
    puts "WARN: No upper-tier instances found. Skip."
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

  puts "INFO: Upper-tier PDN done."
}

# --------------------------
# Top-level PDN flow
# --------------------------
prepare_pdn_floorplan $minCh

setAddStripeMode -orthogonal_only true
setAddStripeMode -ignore_DRC false
setAddStripeMode -extend_to_closest_target area_boundary

build_upper_pdn

puts "INFO: Finished upper-tier PDN."