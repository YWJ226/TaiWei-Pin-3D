############################################################
# Nangate45 3D PDN upper pass
############################################################

puts "INFO: Start Nangate45 upper PDN..."
source $::env(OPENROAD_SCRIPTS_DIR)/pdn_macro_utils.tcl

proc get_row_height_um {{fallback 1.4}} {
  if {[catch {set block [ord::get_db_block]}]} { return $fallback }
  set rows [$block getRows]
  if {[llength $rows] == 0} { return $fallback }
  set row [lindex $rows 0]
  if {[catch {set site [$row getSite]}]} { return $fallback }
  if {$site eq "" || $site eq "NULL"} { return $fallback }
  if {[catch {set h_dbu [$site getHeight]}]} { return $fallback }
  if {$h_dbu <= 0} { return $fallback }
  return [ord::dbu_to_microns $h_dbu]
}

proc derive_mesh_pitch_offset {span_um stripe_width_um requested_pitch_um requested_offset_um} {
  set mfg_grid 0.005
  set span   [expr {double($span_um)}]
  set width  [expr {double($stripe_width_um)}]
  set pitch  [expr {double($requested_pitch_um)}]
  set offset [expr {double($requested_offset_um)}]
  if {$span <= 0.0 || $width <= 0.0} { return [list $pitch $offset] }
  if {$span <= (2.0 * $offset + 2.0 * $width)} {
    set safe_offset 0.0
    set safe_pitch  [expr {round((($span + $width + $mfg_grid) / $mfg_grid)) * $mfg_grid}]
    puts "INFO: Small-core PDN fallback span=$span width=$width requested_pitch=$pitch requested_offset=$offset -> pitch=$safe_pitch offset=$safe_offset"
    return [list $safe_pitch $safe_offset]
  }
  return [list $pitch $offset]
}

proc is_upper_master {master_name} { expr {[string match "*_upper"  $master_name] ? 1 : 0} }
proc is_bottom_master {master_name} { expr {[string match "*_bottom" $master_name] ? 1 : 0} }

proc rename_upper_bottom_insts {} {
  set block [ord::get_db_block]
  foreach inst [$block getInsts] {
    set inst_name [$inst getName]
    set master_name [[$inst getMaster] getName]
    set is_upper  [is_upper_master $master_name]
    set is_bottom [is_bottom_master $master_name]
    if {!$is_upper && !$is_bottom} { continue }
    if {[string match "*_upper" $inst_name] || [string match "*_bottom" $inst_name]} { continue }
    set new_name [expr {$is_upper ? "${inst_name}_upper" : "${inst_name}_bottom"}]
    if {[$block findInst $new_name] ne "NULL"} { continue }
    $inst rename $new_name
  }
}

# rename_upper_bottom_insts

set core_area_bbox [[odb::get_block] getCoreArea]
set core_width  [ord::dbu_to_microns [expr {[$core_area_bbox xMax] - [$core_area_bbox xMin]}]]
set core_height [ord::dbu_to_microns [expr {[$core_area_bbox yMax] - [$core_area_bbox yMin]}]]
set mfg_grid 0.005
set m4_pitch [expr {$core_width / 1.1}]
if {$m4_pitch > 20.16} { set m4_pitch 20.16 }
set m4_pitch [expr {round($m4_pitch / $mfg_grid) * $mfg_grid}]
set m7_pitch [expr {$core_height / 1.1}]
if {$m7_pitch > 40} { set m7_pitch 40 }
set m7_pitch [expr {round($m7_pitch / $mfg_grid) * $mfg_grid}]
lassign [derive_mesh_pitch_offset $core_width 0.84 $m4_pitch 2.0] top_m4_pitch top_m4_offset
lassign [derive_mesh_pitch_offset $core_height 2.4 $m7_pitch 2.0] top_m7_pitch top_m7_offset

or_rebuild_rows_for_site $::env(PLACE_SITE) upper
set rail_pitch [get_row_height_um 1.4]
puts "INFO: Using Nangate45 upper followpins pitch = $rail_pitch um"

clear_global_connect
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDD$} -power
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDPE$}
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDCE$}
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSS$} -ground
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSSE$}
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDD$} -power
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDDPE$}
add_global_connection -net {TOP_VDD} -inst_pattern {.*_upper} -pin_pattern {^VDDCE$}
add_global_connection -net {TOP_VSS} -inst_pattern {.*_upper} -pin_pattern {^VSS$} -ground
add_global_connection -net {TOP_VSS} -inst_pattern {.*_upper} -pin_pattern {^VSSE$}
pin3d_add_macro_global_connections bottom BOT_VDD BOT_VSS
pin3d_add_macro_global_connections upper TOP_VDD TOP_VSS
global_connect

set_voltage_domain -name {Core} -power {TOP_VDD} -ground {TOP_VSS}
report_voltage_domains

define_pdn_grid -name {TOP} -voltage_domains {Core}
add_pdn_stripe -grid {TOP} -layer {M1_m} -width {0.14} -pitch $rail_pitch -offset {0} -followpins -nets {TOP_VDD TOP_VSS}
add_pdn_stripe -grid {TOP} -layer {M4_m} -width {0.84} -pitch $top_m4_pitch -offset $top_m4_offset -nets {TOP_VDD TOP_VSS}
add_pdn_stripe -grid {TOP} -layer {M7_m} -width {2.4} -pitch $top_m7_pitch -offset $top_m7_offset -nets {TOP_VDD TOP_VSS}
add_pdn_connect -grid {TOP} -layers {M1_m M4_m}
add_pdn_connect -grid {TOP} -layers {M4_m M7_m}

# pin3d_add_macro_grids \
#   -tier upper \
#   -grid_prefix TOP \
#   -voltage_domain Core \
#   -nets {TOP_VDD TOP_VSS} \
#   -grid_mode pg_pins \
#   -macro_layers {} \
#   -stripe_widths {} \
#   -stripe_pitches {} \
#   -stripe_offsets {} \
#   -stripe_spacings {} \
#   -connect_layers {{M4_m M7_m}}

# pdngen
puts "INFO: Done Nangate45 upper PDN."
