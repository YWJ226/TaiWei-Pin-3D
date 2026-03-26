########################################################################
# pdn_config_upper.tcl
# Upper-tier PDN only
########################################################################

puts "INFO: pdn_config_upper Start upper-tier PDN..."

proc get_upper_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_upper" -p2]
  if {[llength $inst_ptrs] == 0} { return "" }
  return [dbGet $inst_ptrs.name]
}

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

  deselectAll
  editSelect -layer M1_m -net {TOP_VDD TOP_VSS}
  editDuplicate -layer_horizontal M2_m
  deselectAll

  deselectAll
  editSelect -layer M2_m -net {TOP_VDD TOP_VSS}
  editResize -to 0.018 -side high -direction y -keep_center_line 1
  deselectAll

  catch {setAddStripeMode -stacked_via_top_layer M2_m}
  catch {setAddStripeMode -stacked_via_bottom_layer M3_m}
  addStripe -layer M3_m \
            -direction vertical \
            -nets {TOP_VDD TOP_VSS} \
            -width 0.234 \
            -spacing 0.072 \
            -start_offset 0.300 \
            -set_to_set_distance 5.4

  catch {setAddStripeMode -stacked_via_top_layer M3_m}
  catch {setAddStripeMode -stacked_via_bottom_layer M6_m}
  addStripe -layer M6_m \
            -direction horizontal \
            -nets {TOP_VDD TOP_VSS} \
            -width 0.288 \
            -spacing 0.096 \
            -start_offset 0.513 \
            -set_to_set_distance 5.4

  puts "INFO: pdn_config_upper Upper-tier PDN finished."
}

setAddStripeMode -orthogonal_only true
setAddStripeMode -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

build_upper_pdn