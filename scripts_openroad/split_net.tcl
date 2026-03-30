# ============================================================
# OpenROAD Tcl
# File: split_cross_tier_nets_with_splitter_openroad.tcl
# ============================================================
#
# Function:
#   1. classify pins/cells into upper/lower
#   2. scan all signal nets
#   3. if one net fans out to both upper and lower sinks:
#        - find a 1IN2OUT splitter cell on the same tier as driver
#        - insert splitter after driver
#        - reconnect upper sinks to one splitter output net
#        - reconnect lower sinks to the other splitter output net
#
# Important:
#   - this is NOT cloning the driver
#   - this requires a legal 1-input 2-output combinational cell in the library
#   - if none exists, the net is skipped
#
# Tier classification priority:
#   1) pin regex
#   2) inst regex
#   3) bbox center y compared with split_y_um
#
# Default:
#   dry_run = 1
#

namespace eval ::tier_split_or2 {
  variable CFG
  array set CFG {
    split_y_um               0.0
    use_bbox_split           1
    dry_run                  1
    report_file              tier_split_splitter_openroad.rpt

    upper_inst_re            {}
    lower_inst_re            {}
    upper_pin_re             {}
    lower_pin_re             {}

    upper_master_re          {_upper$}
    lower_master_re          {_bottom$|_lower$}

    splitter_master_upper_re {}
    splitter_master_lower_re {}

    splitter_inst_suffix     __SPLIT
    upper_net_suffix         __TOP
    lower_net_suffix         __BOT
    stem_net_suffix          __STEM

    require_both_sink_tiers  1
    skip_port_driven_nets    1
  }
}

proc ::tier_split_or2::name_matches_any {name patterns} {
  foreach p $patterns {
    if {$p ne "" && [regexp -- $p $name]} { return 1 }
  }
  return 0
}

proc ::tier_split_or2::dbu_per_um {} {
  set tech [ord::get_db_tech]
  return [$tech getDbUnitsPerMicron]
}

proc ::tier_split_or2::split_y_dbu {} {
  variable CFG
  return [expr {round($CFG(split_y_um) * [::tier_split_or2::dbu_per_um])}]
}

proc ::tier_split_or2::inst_center_y_dbu {inst} {
  set box [$inst getBBox]
  return [expr {(double([$box yMin]) + double([$box yMax])) / 2.0}]
}

proc ::tier_split_or2::classify_inst {inst} {
  variable CFG
  set n [$inst getName]

  if {[::tier_split_or2::name_matches_any $n $CFG(upper_inst_re)]} { return upper }
  if {[::tier_split_or2::name_matches_any $n $CFG(lower_inst_re)]} { return lower }

  if {$CFG(use_bbox_split)} {
    if {[::tier_split_or2::inst_center_y_dbu $inst] >= [::tier_split_or2::split_y_dbu]} {
      return upper
    } else {
      return lower
    }
  }
  return unknown
}

proc ::tier_split_or2::iterm_full_name {it} {
  return "[[$it getInst] getName]/[[$it getMTerm] getName]"
}

proc ::tier_split_or2::classify_iterm {it} {
  variable CFG
  set full [::tier_split_or2::iterm_full_name $it]

  if {[::tier_split_or2::name_matches_any $full $CFG(upper_pin_re)]} { return upper }
  if {[::tier_split_or2::name_matches_any $full $CFG(lower_pin_re)]} { return lower }

  return [::tier_split_or2::classify_inst [$it getInst]]
}

proc ::tier_split_or2::safe_sigtype {mterm} {
  if {[catch {set st [$mterm getSigType]}]} { return SIGNAL }
  return $st
}

proc ::tier_split_or2::safe_iotype {mterm} {
  return [$mterm getIoType]
}

proc ::tier_split_or2::master_tier {master} {
  variable CFG
  set mn [$master getName]
  if {[regexp -- $CFG(upper_master_re) $mn]} { return upper }
  if {[regexp -- $CFG(lower_master_re) $mn]} { return lower }
  return unknown
}

proc ::tier_split_or2::master_io_summary {master} {
  set in_cnt 0
  set out_cnt 0
  set out_terms {}
  foreach mt [$master getMTerms] {
    set st [::tier_split_or2::safe_sigtype $mt]
    if {$st eq "POWER" || $st eq "GROUND"} { continue }
    set dir [::tier_split_or2::safe_iotype $mt]
    if {$dir eq "INPUT"} {
      incr in_cnt
    } elseif {$dir eq "OUTPUT"} {
      incr out_cnt
      lappend out_terms [$mt getName]
    } elseif {$dir eq "INOUT"} {
      return [list -1 -1 {}]
    }
  }
  return [list $in_cnt $out_cnt $out_terms]
}

proc ::tier_split_or2::find_splitter_master {tier} {
  variable CFG
  set block [ord::get_db_block]

  set chosen ""
  foreach inst [$block getInsts] {
    set master [$inst getMaster]
    set mn [$master getName]

    if {$tier eq "upper"} {
      if {$CFG(splitter_master_upper_re) ne ""} {
        if {![regexp -- $CFG(splitter_master_upper_re) $mn]} { continue }
      } elseif {[::tier_split_or2::master_tier $master] ne "upper"} {
        continue
      }
    } else {
      if {$CFG(splitter_master_lower_re) ne ""} {
        if {![regexp -- $CFG(splitter_master_lower_re) $mn]} { continue }
      } elseif {[::tier_split_or2::master_tier $master] ne "lower"} {
        continue
      }
    }

    lassign [::tier_split_or2::master_io_summary $master] in_cnt out_cnt out_terms
    if {$in_cnt == 1 && $out_cnt == 2} {
      set chosen $master
      break
    }
  }
  return $chosen
}

proc ::tier_split_or2::driver_ok {drv_it} {
  set inst [$drv_it getInst]
  set master [$inst getMaster]

  if {![catch {set tp [$master getType]}]} {
    if {$tp eq "BLOCK"} { return [list 0 "driver_is_block"] }
  }

  set out_count 0
  foreach it [$inst getITerms] {
    set mt [$it getMTerm]
    set st [::tier_split_or2::safe_sigtype $mt]
    if {$st eq "POWER" || $st eq "GROUND"} { continue }
    set dir [::tier_split_or2::safe_iotype $mt]
    if {$dir eq "OUTPUT"} { incr out_count }
    if {$dir eq "INOUT"} { return [list 0 "driver_has_inout"] }
  }

  if {$out_count != 1} {
    return [list 0 "driver_has_${out_count}_outputs"]
  }
  return [list 1 ""]
}

proc ::tier_split_or2::split_net_with_splitter {block net drv_it upper_sinks lower_sinks fp} {
  variable CFG

  set net_name [$net getName]
  set drv_inst [$drv_it getInst]
  set drv_mterm [$drv_it getMTerm]
  set drv_inst_name [$drv_inst getName]
  set drv_pin_name [$drv_mterm getName]
  set drv_tier [::tier_split_or2::classify_inst $drv_inst]

  set splitter_master [::tier_split_or2::find_splitter_master $drv_tier]
  if {$splitter_master eq ""} {
    puts $fp "SKIP $net_name reason=no_1in2out_splitter_found driver_tier=$drv_tier"
    return 0
  }

  lassign [::tier_split_or2::master_io_summary $splitter_master] in_cnt out_cnt out_terms
  set split_in ""
  set split_out1 [lindex $out_terms 0]
  set split_out2 [lindex $out_terms 1]
  foreach mt [$splitter_master getMTerms] {
    set st [::tier_split_or2::safe_sigtype $mt]
    if {$st eq "POWER" || $st eq "GROUND"} { continue }
    if {[::tier_split_or2::safe_iotype $mt] eq "INPUT"} {
      set split_in [$mt getName]
      break
    }
  }

  set split_inst_name "${drv_inst_name}$CFG(splitter_inst_suffix)__[string map {/ _} $net_name]"
  set stem_net_name   "${net_name}$CFG(stem_net_suffix)"
  set upper_net_name  "${net_name}$CFG(upper_net_suffix)"
  set lower_net_name  "${net_name}$CFG(lower_net_suffix)"

  puts $fp "ACTION SPLIT_NET $net_name DRIVER=$drv_inst_name/$drv_pin_name DRIVER_TIER=$drv_tier SPLITTER=[$splitter_master getName] NEWINST=$split_inst_name"

  if {$CFG(dry_run)} {
    puts $fp "  DRYRUN STEM_NET  $stem_net_name"
    puts $fp "  DRYRUN UPPER_NET $upper_net_name"
    puts $fp "  DRYRUN LOWER_NET $lower_net_name"
    foreach s $upper_sinks { puts $fp "  DRYRUN UPPER_SINK [::tier_split_or2::iterm_full_name $s]" }
    foreach s $lower_sinks { puts $fp "  DRYRUN LOWER_SINK [::tier_split_or2::iterm_full_name $s]" }
    return 1
  }

  # create splitter instance
  set split_inst [odb::dbInst_create $block $splitter_master $split_inst_name]
  set loc [$drv_inst getLocation]
  set x [lindex $loc 0]
  set y [lindex $loc 1]
  $split_inst setLocation $x $y
  $split_inst setOrient [$drv_inst getOrient]
  catch {$split_inst setPlacementStatus [$drv_inst getPlacementStatus]}

  # create nets
  set stem_net  [odb::dbNet_create $block $stem_net_name]
  set upper_net [odb::dbNet_create $block $upper_net_name]
  set lower_net [odb::dbNet_create $block $lower_net_name]

  # reconnect driver output from old net to stem_net
  $drv_it connect $stem_net

  # connect splitter input/output
  set split_in_it  [$split_inst findITerm $split_in]
  set split_o1_it  [$split_inst findITerm $split_out1]
  set split_o2_it  [$split_inst findITerm $split_out2]

  $split_in_it connect $stem_net
  $split_o1_it connect $upper_net
  $split_o2_it connect $lower_net

  # move sinks
  foreach s $upper_sinks {
    $s connect $upper_net
    puts $fp "  MOVED_UPPER [::tier_split_or2::iterm_full_name $s] -> $upper_net_name"
  }
  foreach s $lower_sinks {
    $s connect $lower_net
    puts $fp "  MOVED_LOWER [::tier_split_or2::iterm_full_name $s] -> $lower_net_name"
  }

  return 1
}

proc ::tier_split_or2::run {} {
  variable CFG
  set block [ord::get_db_block]
  set fp [open $CFG(report_file) w]

  puts $fp "# tier_split_or2"
  puts $fp "# dry_run=$CFG(dry_run)"
  puts $fp "# split_y_um=$CFG(split_y_um)"
  puts $fp ""

  puts $fp "## CELL_TIER"
  foreach inst [$block getInsts] {
    puts $fp "CELL [$inst getName] [::tier_split_or2::classify_inst $inst]"
  }
  puts $fp ""

  puts $fp "## PIN_TIER"
  foreach inst [$block getInsts] {
    foreach it [$inst getITerms] {
      puts $fp "PIN [::tier_split_or2::iterm_full_name $it] [::tier_split_or2::classify_iterm $it]"
    }
  }
  puts $fp ""

  puts $fp "## NET_ACTIONS"

  set split_cnt 0
  set skip_cnt 0

  foreach net [$block getNets] {
    set net_name [$net getName]
    set drivers {}
    set upper_sinks {}
    set lower_sinks {}

    foreach it [$net getITerms] {
      set mt  [$it getMTerm]
      set st  [::tier_split_or2::safe_sigtype $mt]
      set dir [::tier_split_or2::safe_iotype $mt]
      if {$st eq "POWER" || $st eq "GROUND"} { continue }

      if {$dir eq "OUTPUT"} {
        lappend drivers $it
      } elseif {$dir eq "INPUT"} {
        set t [::tier_split_or2::classify_iterm $it]
        if {$t eq "upper"} {
          lappend upper_sinks $it
        } elseif {$t eq "lower"} {
          lappend lower_sinks $it
        }
      }
    }

    if {[llength $drivers] != 1} {
      puts $fp "SKIP $net_name reason=driver_count_[llength $drivers]"
      incr skip_cnt
      continue
    }

    if {$CFG(require_both_sink_tiers)} {
      if {[llength $upper_sinks] == 0 || [llength $lower_sinks] == 0} {
        continue
      }
    }

    set drv_it [lindex $drivers 0]
    lassign [::tier_split_or2::driver_ok $drv_it] ok why
    if {!$ok} {
      puts $fp "SKIP $net_name reason=$why"
      incr skip_cnt
      continue
    }

    if {[::tier_split_or2::split_net_with_splitter $block $net $drv_it $upper_sinks $lower_sinks $fp]} {
      incr split_cnt
    } else {
      incr skip_cnt
    }
  }

  puts $fp ""
  puts $fp "# split_count=$split_cnt"
  puts $fp "# skip_count=$skip_cnt"
  close $fp

  puts "tier_split_or2: wrote $CFG(report_file)"
  puts "tier_split_or2: split_count=$split_cnt skip_count=$skip_cnt dry_run=$CFG(dry_run)"
}

# Example:
# namespace eval ::tier_split_or2 {
#   variable CFG
#   set CFG(split_y_um) 500.0
#   set CFG(dry_run) 1
#   set CFG(upper_inst_re) {(^U_TOP_)|(_upper$)}
#   set CFG(lower_inst_re) {(^U_BOT_)|(_bottom$)|(_lower$)}
#   # Optional hard filter if your splitter cell has known naming
#   # set CFG(splitter_master_upper_re) {^SPLIT2_.*_upper$}
#   # set CFG(splitter_master_lower_re) {^SPLIT2_.*_(bottom|lower)$}
# }
# ::tier_split_or2::run