source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

if {![info exists ::env(IO_PLACER_H)] || ![info exists ::env(IO_PLACER_V)]} {
  error "IO_PLACER_H / IO_PLACER_V must be set."
}
set LAYER_H $::env(IO_PLACER_H)
set LAYER_V $::env(IO_PLACER_V)

proc get_die_bbox {} {
  return [ord::get_die_area]
}

proc _io_dbu {} {
  set db [ord::get_db]
  if {$db eq "NULL"} {
    error "OpenDB is not initialized."
  }
  set tech [odb::dbDatabase_getTech $db]
  if {$tech eq "NULL"} {
    error "OpenDB tech is not available."
  }
  return [odb::dbTech_getDbUnitsPerMicron $tech]
}

proc _io_layer {layer_name} {
  set db [ord::get_db]
  if {$db eq "NULL"} {
    error "OpenDB is not initialized."
  }
  set tech [odb::dbDatabase_getTech $db]
  if {$tech eq "NULL"} {
    error "OpenDB tech is not available."
  }
  set layer [odb::dbTech_findLayer $tech $layer_name]
  if {$layer eq "NULL"} {
    error "Routing layer '$layer_name' was not found."
  }
  return $layer
}

proc _io_layer_pitch_um {layer_name} {
  set layer [_io_layer $layer_name]
  set dbu [_io_dbu]
  set candidates {}
  foreach pitch [list [odb::dbTechLayer_getPitchX $layer] [odb::dbTechLayer_getPitchY $layer]] {
    if {$pitch > 0} {
      lappend candidates $pitch
    }
  }
  if {[llength $candidates] == 0} {
    error "Routing layer '$layer_name' does not report a legal pitch."
  }
  return [expr {double([lindex [lsort -integer $candidates] 0]) / double($dbu)}]
}

proc _io_layer_width_um {layer_name} {
  set layer [_io_layer $layer_name]
  set dbu [_io_dbu]
  set width [odb::dbTechLayer_getWidth $layer]
  if {$width <= 0} {
    return [_io_layer_pitch_um $layer_name]
  }
  return [expr {double($width) / double($dbu)}]
}

proc _edge_capacity_from_intervals_um {intervals effective_step_um} {
  if {$effective_step_um <= 0.0} {
    error "effective_step_um must be positive."
  }
  set cap 0
  foreach iv $intervals {
    lassign $iv lo hi
    set seg_len [expr {$hi - $lo}]
    if {$seg_len <= 0.0} {
      continue
    }
    incr cap [expr {int(floor($seg_len / $effective_step_um))}]
  }
  return $cap
}

proc has_bits {base all_list} {
  foreach q $all_list {
    if {[string match "${base}\[*]" $q]} {
      return 1
    }
  }
  return 0
}

proc sanitize_ports {ports all_ports} {
  set keep {}
  array set seen {}
  foreach p $ports {
    if {[regexp -nocase {^(VDD|VSS|VDDA|VSSA|VCCD|VSSD|PWR|GND)} $p]} {
      continue
    }
    if {[regexp {\[[0-9]+\]} $p]} {
      if {![info exists seen($p)]} {
        set seen($p) 1
        lappend keep $p
      }
      continue
    }
    if {[has_bits $p $all_ports]} {
      continue
    }
    if {![info exists seen($p)]} {
      set seen($p) 1
      lappend keep $p
    }
  }
  return [lsort -dictionary -unique $keep]
}

set ins_raw  [lsort -dictionary [all_inputs]]
set outs_raw [lsort -dictionary [all_outputs]]
set all_raw  [concat $ins_raw $outs_raw]
set pins_all [sanitize_ports $all_raw $all_raw]
set N [llength $pins_all]

puts [format "IO-INFO: total ports=%d kept=%d" [llength $all_raw] $N]
if {$N == 0} {
  puts "IO-INFO: no signal pins to place."
  return
}

lassign [get_die_bbox] LX_um LY_um UX_um UY_um
set W_um [expr {$UX_um - $LX_um}]
set H_um [expr {$UY_um - $LY_um}]
if {$W_um <= 0 || $H_um <= 0} {
  error "Invalid die size: W=$W_um H=$H_um"
}

set pitch_h_um [_io_layer_pitch_um $LAYER_H]
set pitch_v_um [_io_layer_pitch_um $LAYER_V]
set width_h_um [_io_layer_width_um $LAYER_H]
set width_v_um [_io_layer_width_um $LAYER_V]

# In OpenROAD edge placement, the effective legal pin-to-pin pitch on our
# boundary layers is two routing tracks. This matches the generated
# io_pin_placement.txt files and the official pin-placer definition where the
# default min distance is two routing tracks. Keep the script aligned to that
# model instead of using a die-percentage heuristic.
set base_step_h_um [expr {2.0 * $pitch_h_um}]
set base_step_v_um [expr {2.0 * $pitch_v_um}]

# Keep the corner margin tied to the physical pin shape size, not a percentage
# of the die. This avoids over-pruning small designs while still reserving one
# legal pin footprint from each corner.
set corner_margin_um [expr {max($base_step_h_um, $base_step_v_um)}]

set edge_h_interval [list [list $corner_margin_um [expr {$W_um - $corner_margin_um}]]]
set edge_v_interval [list [list $corner_margin_um [expr {$H_um - $corner_margin_um}]]]
set gross_slots_bottom [_edge_capacity_from_intervals_um $edge_h_interval $base_step_h_um]
set gross_slots_top    $gross_slots_bottom
set gross_slots_left   [_edge_capacity_from_intervals_um $edge_v_interval $base_step_v_um]
set gross_slots_right  $gross_slots_left
set gross_total_slots  [expr {$gross_slots_bottom + $gross_slots_top + $gross_slots_left + $gross_slots_right}]

set min_tracks 2
set min_dist_h_um [expr {$min_tracks * $pitch_h_um}]
set min_dist_v_um [expr {$min_tracks * $pitch_v_um}]
set chosen_capacity_bottom [_edge_capacity_from_intervals_um $edge_h_interval $min_dist_h_um]
set chosen_capacity_top    $chosen_capacity_bottom
set chosen_capacity_left   [_edge_capacity_from_intervals_um $edge_v_interval $min_dist_v_um]
set chosen_capacity_right  $chosen_capacity_left
set chosen_capacity [expr {
  $chosen_capacity_bottom +
  $chosen_capacity_top +
  $chosen_capacity_left +
  $chosen_capacity_right
}]

clear_io_pin_constraints

puts [format "IO-DIE(um): W=%.6f H=%.6f corner_margin=%.6f" \
  $W_um $H_um $corner_margin_um]
puts [format "IO-LAYERS: top_bottom=%s pitch=%.6f width=%.6f | left_right=%s pitch=%.6f width=%.6f" \
  $LAYER_H $pitch_h_um $width_h_um $LAYER_V $pitch_v_um $width_v_um]
puts [format "IO-CAPACITY(gross_slots): top=%d bottom=%d left=%d right=%d total=%d pins=%d" \
  $gross_slots_top $gross_slots_bottom $gross_slots_left $gross_slots_right $gross_total_slots $N]
puts [format "IO-SPACING: base_step_h=%.6f base_step_v=%.6f min_dist_tracks=%d min_dist_h=%.6f min_dist_v=%.6f chosen_capacity=%d" \
  $base_step_h_um $base_step_v_um $min_tracks $min_dist_h_um $min_dist_v_um $chosen_capacity]

if {$chosen_capacity < $N} {
  error [format "IO capacity is insufficient on the raw boundary slot model: capacity=%d pins=%d" \
    $chosen_capacity $N]
}

set pin_dump [file join $::env(LOG_DIR) "io_pin_placement.txt"]
log_cmd place_pins \
  -hor_layers $LAYER_H \
  -ver_layers $LAYER_V \
  -corner_avoidance $corner_margin_um \
  -min_distance $min_tracks \
  -min_distance_in_tracks \
  -write_pin_placement $pin_dump

puts "FINAL: deterministic IO pins placed without side-order constraints."
