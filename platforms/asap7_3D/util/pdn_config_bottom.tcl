########################################################################
# pdn_config_bottom.tcl
# Bottom-tier PDN only
########################################################################

puts "INFO: pdn_config_bottom Start bottom-tier PDN..."
source $::env(CADENCE_SCRIPTS_DIR)/place_macro_util.tcl

proc get_bottom_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_bottom" -p2]
  if {[llength $inst_ptrs] == 0} { return "" }
  return [dbGet $inst_ptrs.name]
}

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

  deselectAll
  editSelect -layer M1 -net {BOT_VDD BOT_VSS}
  editDuplicate -layer_horizontal M2
  deselectAll

  deselectAll
  editSelect -layer M2 -net {BOT_VDD BOT_VSS}
  editResize -to 0.018 -side high -direction y -keep_center_line 1
  deselectAll

  catch {setAddStripeMode -stacked_via_top_layer M3}
  catch {setAddStripeMode -stacked_via_bottom_layer M2}
  addStripe -layer M3 \
            -direction vertical \
            -nets {BOT_VDD BOT_VSS} \
            -width 0.234 \
            -spacing 0.072 \
            -start_offset 0.300 \
            -set_to_set_distance 5.4

  catch {setAddStripeMode -stacked_via_top_layer M6}
  catch {setAddStripeMode -stacked_via_bottom_layer M3}
  addStripe -layer M6 \
            -direction horizontal \
            -nets {BOT_VDD BOT_VSS} \
            -width 0.288 \
            -spacing 0.096 \
            -start_offset 0.513 \
            -set_to_set_distance 5.4

  puts "INFO: pdn_config_bottom Bottom-tier PDN finished."
}

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

# 3) Build bottom-tier PDN
build_bottom_pdn
