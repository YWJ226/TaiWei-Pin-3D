# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
########################################################################
# place_pin.tcl
#   Uniform IO pin placement on perimeter with corner avoidance.
#   - Uses global Tcl variables: IO_PLACER_H (LEFT/RIGHT), IO_PLACER_V (BOTTOM/TOP)
#   - Distributes ALL signal IOs (excludes obvious P/G) along 4 sides
#   - Corner margin = 5% of short side
#   - Places pins one–by–one with -assign/-snap TRACK to avoid IMPPTN-970
########################################################################

# Flatten various dbGet box formats into {lx ly ux uy}
proc __box_flat4 {box} {
  set nums {}
  set s "$box"
  foreach tok [split $s " \t\r\n{}"] {
    if {$tok eq ""} { continue }
    if {![string is double -strict $tok]} { continue }
    lappend nums $tok
  }
  if {[llength $nums] != 4} {
    error "Unsupported top.fPlan.box format: $box"
  }
  return $nums
}

# Parse pin name into {group_name index original_name}.
# Examples:
proc __pin_group_triplet {name} {
  if {[regexp {^(.*)\[([0-9]+)\]$} $name -> base idx]} {
    return [list $base $idx $name]
  }

  if {[regexp {^(.*?)(?:_)?([0-9]+)$} $name -> base idx]} {
    regsub {_$} $base "" base
    if {$base ne ""} {
      return [list $base $idx $name]
    }
  }

  return [list $name -1 $name]
}

# Build grouped pin list:
#   {
#     {groupA {pinA0 pinA1 ...}}
#     {groupB {pinB0 pinB1 ...}}
#   }
proc __build_pin_groups {pins} {
  set groups_dict [dict create]

  foreach pin $pins {
    lassign [__pin_group_triplet $pin] group idx orig
    dict lappend groups_dict $group [list $idx $orig]
  }

  set grouped {}
  foreach group [lsort -dictionary [dict keys $groups_dict]] {
    set items [dict get $groups_dict $group]

    set all_indexed 1
    foreach item $items {
      if {[lindex $item 0] < 0} {
        set all_indexed 0
        break
      }
    }

    if {$all_indexed} {
      set items [lsort -integer -index 0 $items]
    } else {
      set items [lsort -dictionary -index 1 $items]
    }

    set ordered_pins {}
    foreach item $items {
      lappend ordered_pins [lindex $item 1]
    }

    lappend grouped [list $group $ordered_pins]
  }

  return $grouped
}

# Assign groups to sides while keeping each group contiguous.
# Side order follows the perimeter: BOTTOM -> RIGHT -> TOP -> LEFT.
proc __assign_groups_to_sides {grouped usableB usableR} {
  set side_order {BOTTOM RIGHT TOP LEFT}
  set side_len [dict create \
    BOTTOM $usableB \
    RIGHT  $usableR \
    TOP    $usableB \
    LEFT   $usableR]

  set total_pins 0
  foreach rec $grouped {
    incr total_pins [llength [lindex $rec 1]]
  }

  set usable_perim [expr {2.0 * ($usableB + $usableR)}]

  set side_target [dict create]
  set sum_target 0
  foreach side $side_order {
    set t [expr {int(round($total_pins * [dict get $side_len $side] / $usable_perim))}]
    dict set side_target $side $t
    incr sum_target $t
  }

  while {$sum_target < $total_pins} {
    foreach side $side_order {
      dict incr side_target $side 1
      incr sum_target
      if {$sum_target == $total_pins} { break }
    }
  }

  while {$sum_target > $total_pins} {
    foreach side [lreverse $side_order] {
      if {[dict get $side_target $side] > 0} {
        dict incr side_target $side -1
        incr sum_target -1
        if {$sum_target == $total_pins} { break }
      }
    }
  }

  set side_groups [dict create \
    BOTTOM {} \
    RIGHT  {} \
    TOP    {} \
    LEFT   {}]

  set side_count [dict create \
    BOTTOM 0 \
    RIGHT  0 \
    TOP    0 \
    LEFT   0]

  set side_idx 0
  foreach rec $grouped {
    lassign $rec group pins
    set gsz [llength $pins]

    while {1} {
      set side [lindex $side_order $side_idx]
      set cur  [dict get $side_count $side]
      set tgt  [dict get $side_target $side]

      if {$side_idx == [expr {[llength $side_order] - 1}]} {
        set lst [dict get $side_groups $side]
        lappend lst [list $group $pins]
        dict set side_groups $side $lst
        dict incr side_count $side $gsz
        break
      }

      if {$cur == 0 || ($cur + $gsz) <= $tgt} {
        set lst [dict get $side_groups $side]
        lappend lst [list $group $pins]
        dict set side_groups $side $lst
        dict incr side_count $side $gsz
        break
      }

      incr side_idx
    }
  }

  return $side_groups
}

# Flatten grouped records on one side into a pin list.
proc __flatten_side_groups {side_groups side} {
  set out {}
  foreach rec [dict get $side_groups $side] {
    foreach pin [lindex $rec 1] {
      lappend out $pin
    }
  }
  return $out
}

# Place all pins on one side with uniform spacing.
proc __place_side_pins {pins side lx ly ux uy cm layerH layerV} {
  set n [llength $pins]
  if {$n == 0} {
    return
  }

  switch -- $side {
    BOTTOM {
      set usable [expr {$ux - $lx - 2.0 * $cm}]
      set pitch  [expr {$usable / double($n)}]
      set layer  $layerV
      for {set i 0} {$i < $n} {incr i} {
        set pin [lindex $pins $i]
        set x   [expr {$lx + $cm + ($i + 0.5) * $pitch}]
        set y   $ly
        editPin -pin $pin -layer $layer -side $side \
                -assign "$x $y" -snap TRACK -fixOverlap 1 \
                -skipWrappingPins -global_location
      }
    }

    RIGHT {
      set usable [expr {$uy - $ly - 2.0 * $cm}]
      set pitch  [expr {$usable / double($n)}]
      set layer  $layerH
      for {set i 0} {$i < $n} {incr i} {
        set pin [lindex $pins $i]
        set x   $ux
        set y   [expr {$ly + $cm + ($i + 0.5) * $pitch}]
        editPin -pin $pin -layer $layer -side $side \
                -assign "$x $y" -snap TRACK -fixOverlap 1 \
                -skipWrappingPins -global_location
      }
    }

    TOP {
      set usable [expr {$ux - $lx - 2.0 * $cm}]
      set pitch  [expr {$usable / double($n)}]
      set layer  $layerV
      for {set i 0} {$i < $n} {incr i} {
        set pin [lindex $pins $i]
        set x   [expr {$ux - $cm - ($i + 0.5) * $pitch}]
        set y   $uy
        editPin -pin $pin -layer $layer -side $side \
                -assign "$x $y" -snap TRACK -fixOverlap 1 \
                -skipWrappingPins -global_location
      }
    }

    LEFT {
      set usable [expr {$uy - $ly - 2.0 * $cm}]
      set pitch  [expr {$usable / double($n)}]
      set layer  $layerH
      for {set i 0} {$i < $n} {incr i} {
        set pin [lindex $pins $i]
        set x   $lx
        set y   [expr {$uy - $cm - ($i + 0.5) * $pitch}]
        editPin -pin $pin -layer $layer -side $side \
                -assign "$x $y" -snap TRACK -fixOverlap 1 \
                -skipWrappingPins -global_location -quiet
      }
    }

    default {
      error "Unsupported side: $side"
    }
  }
}

proc place_all_ios {} {
  if {![info exists ::env(IO_PLACER_H)] || ![info exists ::env(IO_PLACER_V)]} {
    error "Environment variables IO_PLACER_H and IO_PLACER_V must be set before calling place_all_ios."
  }

  set layerH $::env(IO_PLACER_H)
  set layerV $::env(IO_PLACER_V)

  # Collect signal IOs only.
  set pins {}
  foreach t [dbGet top.terms] {
    set name [dbGet $t.name]
    if {[regexp -nocase {^(VDD|VSS|VDDA|VSSA|VCCD|VSSD|PWR|GND)} $name]} {
      continue
    }
    lappend pins $name
  }

  set pins [lsort -dictionary -unique $pins]
  set N [llength $pins]
  if {$N == 0} {
    puts "IO-INFO: No signal IO pins found. Nothing to place."
    return
  }

  set flat [__box_flat4 [dbGet top.fPlan.box]]
  lassign $flat lx ly ux uy

  set W [expr {$ux - $lx}]
  set H [expr {$uy - $ly}]
  set short [expr {$W < $H ? $W : $H}]

  set cm [expr {0.05 * $short}]
  set usableB [expr {$W - 2.0 * $cm}]
  set usableR [expr {$H - 2.0 * $cm}]

  if {$usableB <= 0.0 || $usableR <= 0.0} {
    set cm 0.0
    set usableB $W
    set usableR $H
  }

  set grouped     [__build_pin_groups $pins]
  set side_groups [__assign_groups_to_sides $grouped $usableB $usableR]

  puts [format "IO-INFO: total_pins=%d grouped_sets=%d" $N [llength $grouped]]
  foreach side {BOTTOM RIGHT TOP LEFT} {
    set plist [__flatten_side_groups $side_groups $side]
    puts [format "IO-INFO: %-6s count=%d" $side [llength $plist]]
  }

  setPinAssignMode -pinEditInBatch true

  foreach side {BOTTOM RIGHT TOP LEFT} {
    set plist [__flatten_side_groups $side_groups $side]
    __place_side_pins $plist $side $lx $ly $ux $uy $cm $layerH $layerV
  }

  setPinAssignMode -pinEditInBatch false
  legalizePin -keepLayer -moveFixedPin

  puts "FINAL: IO pins placed by grouped-name ordering and legalized."
}

place_all_ios