#################################################################
# pdn_config_simple_bottom.tcl
# Minimal 3D PDN for bottom tier only
#################################################################

puts "INFO: Start bottom-tier PDN..."

# --------------------------
# Basic floorplan channels
# --------------------------
set minCh 5

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
# Common PDN floorplan prep
# --------------------------
proc prepare_pdn_floorplan {min_ch} {
  dbSet [dbGet top.insts.cell.subClass core -p2].pStatus unplaced
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
# Build bottom-tier PDN
# --------------------------
proc build_bottom_pdn {} {
  set inst_list [get_bottom_tier_insts]

  puts "INFO: BOT inst count = [llength $inst_list]"
  if {[llength $inst_list] == 0} {
    puts "WARN: No bottom-tier instances found. Skip."
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

  puts "INFO: Bottom-tier PDN done."
}

# --------------------------
# Top-level PDN flow
# --------------------------
prepare_pdn_floorplan $minCh

setAddStripeMode -orthogonal_only true
setAddStripeMode -ignore_DRC false
setAddStripeMode -extend_to_closest_target area_boundary

clearGlobalNets
build_bottom_pdn

puts "INFO: Finished bottom-tier PDN."