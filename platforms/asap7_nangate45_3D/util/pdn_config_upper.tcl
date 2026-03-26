########################################################################
# pdn_3d_stacked_upper.tcl
# 3D PDN for Innovus - upper tier only
# Top : TOP_VDD / TOP_VSS
# Layers : M1_m/M2_m rails + M3_m(V) + M6_m(H)
########################################################################

source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
puts "INFO:pdn_3d_stacked_upperStart upper-tier PDN..."

########################################################################
# Tier instance quer######################################################################
proc get_upper_tier_insts {} {
  set inst_ptrs [dbGet top.insts.cell.name "*_upper" -p2]
  if {[llength $inst_ptrs] == 0} { return "" }
  return [dbGet $inst_ptrs.name]
}

########################################################################
# Upper tier PDN
########################################################################

# 2) Global net connections for upper tier only
set nets_top [list TOP_VDD TOP_VSS]

set top_insts [get_upper_tier_insts]
if {[llength $top_insts] == 0} {
  puts "WARN: pdn_3d_stacked_upper No *_upper masters found."
} else {
  puts "INFO: pdn_3d_stacked_upperOP tier instanccount [llength $top_insts]"
  foreach inst $top_insts {
    globalNetConnect TOP_VDD -type pgpin -pin VDD -inst $inst -override
    globalNetConnect TOP_VSS -type pgpin -pin VSS -inst $inst -override
  }
}

globalNetConnect TOP_VDD -type tiehi -all -override
globalNetConnect TOP_VSS -type tielo -all -override

# 3a) Follow-pin rails for TOP on M1_m
sroute -nets $nets_top \
       -connect {corePin} \
       -corePinLayer {M1_m} \
       -corePinTarget {firstAfterRowEnd}

# 3b) Duplicate M1_m rails to M2_m
deselectAll
editSelect -layer M1_m -net $nets_top
editDuplicate -layer_horizontal M2_m
deselectAll

deselectAll
editSelect -layer M2_m -net $nets_top
editResize -to 0.018 -side high -direction y -keep_center_line 1
deselectAll

# 4) TOP mesh on M3_m (vertical) / M6_m (horizontal)
setAddStripeMode -orthogonal_only true -ignore_DRC false
setAddStripeMode -over_row_extension true
setAddStripeMode -extend_to_closest_target area_boundary
setAddStripeMode -inside_cell_only false
setAddStripeMode -route_over_rows_only false

setAddStripeMode -stacked_via_top_layer M2_m -stacked_via_bottom_layer M3_m
addStripe -layer M3_m \
          -direction vertical \
          -nets $nets_top \
          -width 0.234 \
          -spacing 0.072 \
          -start_offset 0.300 \
          -set_to_set_distance 5.4

setAddStripeMode -stacked_via_top_layer M3_m -stacked_via_bottom_layer M6_m
addStripe -layer M6_m \
          -direction horizontal \
          -nets $nets_top \
          -width 0.288 \
          -spacing 0.096 \
          -start_offset 0.513 \
          -set_to_set_distance 5.4

puts "INFO: pdn_3d_stacked_upper Upper-tier PDN finished."