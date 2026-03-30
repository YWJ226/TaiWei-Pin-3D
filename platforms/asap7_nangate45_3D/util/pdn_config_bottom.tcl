########################################################################
# pdn_3d_stacked_bottom.tcl
# 3D PDN for Innovus - bottom tier only
# Bottom : BOT_VDD / BOT_VSS
# Layers : M1 rails + M4(V) + M7(H)
########################################################################

source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
puts "INFO: pdn_3d_stacked_bottom Start bottom-tier PDN..."

########################################################################
# Tier instance query
########################################################################
proc get_bottom_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_bottom" -p2]
  if {[llength $inst_ptrs] == 0} { return "" }
  return [dbGet $inst_ptrs.name]
}

########################################################################
# Bottom tier PDN
########################################################################

set minCh 2

# 1) Unplace core cells and cut rows
set core_insts [dbGet top.insts.cell.subClass core -p2]
if {[llength $core_insts] > 0} {
  dbSet $core_insts.pStatus unplaced
}
finishFloorplan -fillPlaceBlockage hard $minCh
cutRow
finishFloorplan -fillPlaceBlockage hard $minCh

# Remove temporary place blockages
set fp_blk [dbGet top.fPlan.pBlkgs.name finishfp_place_blkg_* -p1]
if {[llength $fp_blk] > 0} {
  deselectAll
  select_obj $fp_blk
  deleteSelectedFromFPlan
  deselectAll
}

# 2) Global net connections for bottom tier only
set nets_bot [list BOT_VDD BOT_VSS]
clearGlobalNets

set bot_insts [get_bottom_tier_insts]
if {[llength $bot_insts] == 0} {
  puts "WARN: pdn_3d_stacked_bottom No *_bottom masters found."
} else {
  puts "INFO: pdn_3d_stacked_bottom BOT tier instance count [llength $bot_insts]"
  foreach inst $bot_insts {
    globalNetConnect BOT_VDD -type pgpin -pin VDD -inst $inst -override
    globalNetConnect BOT_VSS -type pgpin -pin VSS -inst $inst -override
  }
}

globalNetConnect BOT_VDD -type tiehi -all -override
globalNetConnect BOT_VSS -type tielo -all -override

# 3) Via generation housekeeping
setGenerateViaMode -auto true
generateVias
editDelete -type Special -net $nets_bot
setViaGenMode -ignore_DRC false
setViaGenMode -optimize_cross_via true
setViaGenMode -allow_wire_shape_change false
setViaGenMode -extend_out_wire_end false
setViaGenMode -viarule_preference generated

# 4) Follow-pin rails for BOT on M1
sroute -nets {BOT_VDD BOT_VSS} \
       -connect {corePin} \
       -corePinLayer {M1} \
       -corePinTarget {firstAfterRowEnd}

# 5) BOT mesh on M4 (vertical) / M7 (horizontal)
setAddStripeMode -orthogonal_only true -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

setAddStripeMode -stacked_via_bottom_layer M1 -stacked_via_top_layer M4
addStripe -layer M4 \
          -direction vertical \
          -nets $nets_bot \
          -width 0.84 \
          -spacing 0.84 \
          -start_offset 0.0 \
          -set_to_set_distance 20.16

setAddStripeMode -stacked_via_bottom_layer M4 -stacked_via_top_layer M7
addStripe -layer M7 \
          -direction horizontal \
          -nets $nets_bot \
          -width 2.4 \
          -spacing 2.4 \
          -start_offset 2.0 \
          -set_to_set_distance 40.0

puts "INFO: pdn_3d_stacked_bottom Bottom-tier PDN finished."