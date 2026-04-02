############################################################
# ASAP7 3D PDN bottom pass
############################################################

puts "INFO: Start ASAP7 bottom PDN..."

proc get_row_height_um {{fallback 0.27}} {
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
or_rebuild_rows_for_site $::env(PLACE_SITE) bottom

set rail_pitch [get_row_height_um 0.27]
puts "INFO: Using ASAP7 bottom followpins pitch = $rail_pitch um"

clear_global_connect
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDD$} -power
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDPE$}
add_global_connection -net {BOT_VDD} -inst_pattern {.*_bottom} -pin_pattern {^VDDCE$}
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSS$} -ground
add_global_connection -net {BOT_VSS} -inst_pattern {.*_bottom} -pin_pattern {^VSSE$}
global_connect

set_voltage_domain -name {Core} -power {BOT_VDD} -ground {BOT_VSS}
report_voltage_domains

define_pdn_grid -name {BOT} -voltage_domains {Core}
add_pdn_stripe -grid {BOT} -layer {M1} -width {0.018} -pitch $rail_pitch -offset {0} -followpins -nets {BOT_VDD BOT_VSS}
add_pdn_stripe -grid {BOT} -layer {M2} -width {0.018} -pitch $rail_pitch -offset {0} -followpins -nets {BOT_VDD BOT_VSS}
add_pdn_stripe -grid {BOT} -layer {M3} -width {0.234} -spacing {0.072} -pitch {5.4} -offset {0.300} -nets {BOT_VDD BOT_VSS}
add_pdn_stripe -grid {BOT} -layer {M6} -width {0.288} -spacing {0.096} -pitch {5.4} -offset {0.513} -nets {BOT_VDD BOT_VSS}
add_pdn_connect -grid {BOT} -layers {M1 M2}
add_pdn_connect -grid {BOT} -layers {M2 M3}
add_pdn_connect -grid {BOT} -layers {M3 M6}

pdngen
puts "INFO: Done ASAP7 bottom PDN."
