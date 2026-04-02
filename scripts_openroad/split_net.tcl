# ============================================================
# OpenROAD Tcl
# File: split_net.tcl
# Regular-buffer split pass for mixed-tier signal nets.
#
# This matches the Cadence split-net intent:
#   driver -> original_net -> retained sinks + buffer input
#   buffer -> branch_net   -> moved sinks
#
# The pass runs after IO placement and before macro placement. It does not
# require a special 1-input/2-output splitter cell; it uses a regular 1-input
# / 1-output buffer on the selected tier.
# ============================================================

if {![llength [info commands _or_bterm_tier]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
}

namespace eval ::tier_split_or2 {
  variable CFG
  array set CFG {
    split_y_um               0.0
    use_bbox_split           1
    dry_run                  1
    report_file              tier_split_buffer_openroad.rpt

    upper_inst_re            {}
    lower_inst_re            {}
    upper_pin_re             {}
    lower_pin_re             {}

    upper_master_re          {_upper$}
    lower_master_re          {_bottom$|_lower$}

    buffer_master_upper_re   {}
    buffer_master_lower_re   {}

    buffer_inst_suffix       __PIN3DSPLITBUF__
    branch_net_suffix        __BRANCH

    require_both_sink_tiers  1
    skip_port_driven_nets    1
  }
}

proc ::tier_split_or2::name_matches_any {name patterns} {
  foreach p $patterns {
    if {$p ne "" && [regexp -- $p $name]} {
      return 1
    }
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
  set name [$inst getName]

  if {[llength [info commands _or_inst_tier]]} {
    set canonical_tier [_or_inst_tier $inst]
    if {$canonical_tier eq "upper" || $canonical_tier eq "bottom"} {
      return $canonical_tier
    }
  }

  if {[::tier_split_or2::name_matches_any $name $CFG(upper_inst_re)]} {
    return upper
  }
  if {[::tier_split_or2::name_matches_any $name $CFG(lower_inst_re)]} {
    return bottom
  }

  if {$CFG(use_bbox_split)} {
    if {[::tier_split_or2::inst_center_y_dbu $inst] >= [::tier_split_or2::split_y_dbu]} {
      return upper
    }
    return bottom
  }
  return unknown
}

proc ::tier_split_or2::iterm_full_name {iterm} {
  return "[[$iterm getInst] getName]/[[$iterm getMTerm] getName]"
}

proc ::tier_split_or2::classify_iterm {iterm} {
  variable CFG
  set full [::tier_split_or2::iterm_full_name $iterm]

  if {[::tier_split_or2::name_matches_any $full $CFG(upper_pin_re)]} {
    return upper
  }
  if {[::tier_split_or2::name_matches_any $full $CFG(lower_pin_re)]} {
    return bottom
  }
  return [::tier_split_or2::classify_inst [$iterm getInst]]
}

proc ::tier_split_or2::safe_sigtype {term} {
  if {[catch {set sig_type [$term getSigType]}]} {
    return SIGNAL
  }
  return $sig_type
}

proc ::tier_split_or2::safe_iotype {term} {
  if {[catch {set io_type [$term getIoType]}]} {
    return ""
  }
  return $io_type
}

proc ::tier_split_or2::bterm_role {bterm} {
  set dir [::tier_split_or2::safe_iotype $bterm]
  switch -- $dir {
    INPUT  { return driver }
    OUTPUT { return sink }
    default { return unsupported }
  }
}

proc ::tier_split_or2::bterm_tier {bterm} {
  if {[llength [info commands _or_bterm_tier]]} {
    return [_or_bterm_tier $bterm]
  }
  return unknown
}

proc ::tier_split_or2::master_tier {master} {
  variable CFG
  set master_name [$master getName]
  if {[regexp -- $CFG(upper_master_re) $master_name]} {
    return upper
  }
  if {[regexp -- $CFG(lower_master_re) $master_name]} {
    return bottom
  }
  return unknown
}

proc ::tier_split_or2::master_has_site {master} {
  if {[catch {set site [$master getSite]}]} {
    return 0
  }
  return [expr {$site ne "" && $site ne "NULL"}]
}

proc ::tier_split_or2::master_io_summary {master} {
  set in_cnt 0
  set out_cnt 0
  set input_term ""
  set output_term ""

  foreach mterm [$master getMTerms] {
    set sig_type [::tier_split_or2::safe_sigtype $mterm]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    set dir [::tier_split_or2::safe_iotype $mterm]
    switch -- $dir {
      INPUT {
        incr in_cnt
        set input_term [$mterm getName]
      }
      OUTPUT {
        incr out_cnt
        set output_term [$mterm getName]
      }
      INOUT {
        return [list -1 -1 "" ""]
      }
    }
  }
  return [list $in_cnt $out_cnt $input_term $output_term]
}

proc ::tier_split_or2::buffer_name_is_usable {master_name} {
  if {![regexp -nocase -- {^buf} $master_name]} {
    return 0
  }
  if {[regexp -nocase -- {^(clkbuf|tbuf)} $master_name]} {
    return 0
  }
  return 1
}

proc ::tier_split_or2::find_master_by_name {master_name} {
  set db [ord::get_db]
  foreach lib [::odb::dbDatabase_getLibs $db] {
    foreach master [::odb::dbLib_getMasters $lib] {
      if {[$master getName] eq $master_name} {
        return $master
      }
    }
  }
  return ""
}

proc ::tier_split_or2::buffer_drive_score {master_name} {
  set score 999999
  if {[regexp -nocase -- {[_x]([0-9]+)(?:_|$)} $master_name -> drive]} {
    set score $drive
  }
  return $score
}

proc ::tier_split_or2::choose_buffer_master {tier} {
  variable CFG
  set fallback {}
  set db [ord::get_db]
  foreach lib [::odb::dbDatabase_getLibs $db] {
    foreach master [::odb::dbLib_getMasters $lib] {
      set master_name [$master getName]
      if {![::tier_split_or2::master_has_site $master]} {
        continue
      }
      if {![::tier_split_or2::buffer_name_is_usable $master_name]} {
        continue
      }
      if {$tier eq "upper"} {
        if {$CFG(buffer_master_upper_re) ne "" && ![regexp -- $CFG(buffer_master_upper_re) $master_name]} {
          continue
        }
      } else {
        if {$CFG(buffer_master_lower_re) ne "" && ![regexp -- $CFG(buffer_master_lower_re) $master_name]} {
          continue
        }
      }
      if {[::tier_split_or2::master_tier $master] ne $tier} {
        continue
      }
      lassign [::tier_split_or2::master_io_summary $master] in_cnt out_cnt input_term output_term
      if {$in_cnt == 1 && $out_cnt == 1 && $input_term ne "" && $output_term ne ""} {
        lappend fallback [list [::tier_split_or2::buffer_drive_score $master_name] $master_name $input_term $output_term]
      }
    }
  }

  if {[llength $fallback] == 0} {
    return ""
  }
  set sorted [lsort -integer -index 0 [lsort -dictionary -index 1 $fallback]]
  return [lrange [lindex $sorted 0] 1 end]
}

proc ::tier_split_or2::driver_ok {driver_iterm} {
  set inst [$driver_iterm getInst]
  set master [$inst getMaster]

  if {![catch {set master_type [$master getType]}] && $master_type eq "BLOCK"} {
    return [list 0 "driver_is_block"]
  }
  foreach iterm [$inst getITerms] {
    set sig_type [::tier_split_or2::safe_sigtype [$iterm getMTerm]]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    set dir [::tier_split_or2::safe_iotype [$iterm getMTerm]]
    if {$dir eq "INOUT"} {
      return [list 0 "driver_has_inout"]
    }
  }
  return [list 1 ""]
}

proc ::tier_split_or2::object_label {kind obj} {
  switch -- $kind {
    iterm {
      return [::tier_split_or2::iterm_full_name $obj]
    }
    bterm {
      return [$obj getName]
    }
    default {
      return "<unknown>"
    }
  }
}

proc ::tier_split_or2::get_net_driver {net} {
  variable CFG
  set drivers {}

  foreach iterm [$net getITerms] {
    set sig_type [::tier_split_or2::safe_sigtype [$iterm getMTerm]]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    if {[::tier_split_or2::safe_iotype [$iterm getMTerm]] eq "OUTPUT"} {
      lappend drivers [list iterm $iterm]
    }
  }

  if {![catch {set bterms [$net getBTerms]}]} {
    foreach bterm $bterms {
      set sig_type [::tier_split_or2::safe_sigtype $bterm]
      if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
        continue
      }
      if {[::tier_split_or2::bterm_role $bterm] eq "driver"} {
        lappend drivers [list bterm $bterm]
      }
    }
  }

  if {[llength $drivers] != 1} {
    return [list "" "driver_count_[llength $drivers]"]
  }

  lassign [lindex $drivers 0] driver_kind driver_obj
  if {$driver_kind eq "bterm"} {
    if {$CFG(skip_port_driven_nets)} {
      return [list "" "top_level_term_net_not_supported"]
    }
    return [list "" "top_level_term_driver_not_supported"]
  }

  lassign [::tier_split_or2::driver_ok $driver_obj] ok reason
  if {!$ok} {
    return [list "" $reason]
  }
  return [list [list $driver_kind $driver_obj] ""]
}

proc ::tier_split_or2::collect_sinks_by_tier {net} {
  set upper_inst_sinks {}
  set bottom_inst_sinks {}
  set upper_term_sinks {}
  set bottom_term_sinks {}
  set unknown_sinks {}

  foreach iterm [$net getITerms] {
    set sig_type [::tier_split_or2::safe_sigtype [$iterm getMTerm]]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    if {[::tier_split_or2::safe_iotype [$iterm getMTerm]] ne "INPUT"} {
      continue
    }
    switch -- [::tier_split_or2::classify_iterm $iterm] {
      upper {
        lappend upper_inst_sinks $iterm
      }
      bottom {
        lappend bottom_inst_sinks $iterm
      }
      default {
        lappend unknown_sinks [list iterm $iterm]
      }
    }
  }

  if {![catch {set bterms [$net getBTerms]}]} {
    foreach bterm $bterms {
      set sig_type [::tier_split_or2::safe_sigtype $bterm]
      if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
        continue
      }
      if {[::tier_split_or2::bterm_role $bterm] ne "sink"} {
        continue
      }
      switch -- [::tier_split_or2::bterm_tier $bterm] {
        upper {
          lappend upper_term_sinks $bterm
        }
        bottom {
          lappend bottom_term_sinks $bterm
        }
        default {
          lappend unknown_sinks [list bterm $bterm]
        }
      }
    }
  }

  return [dict create \
    upper_inst $upper_inst_sinks \
    bottom_inst $bottom_inst_sinks \
    upper_term $upper_term_sinks \
    bottom_term $bottom_term_sinks \
    unknown $unknown_sinks]
}

proc ::tier_split_or2::choose_buffer_tier {sinks_by_tier} {
  set upper_inst_count [llength [dict get $sinks_by_tier upper_inst]]
  set bottom_inst_count [llength [dict get $sinks_by_tier bottom_inst]]
  set upper_term_count [llength [dict get $sinks_by_tier upper_term]]
  set bottom_term_count [llength [dict get $sinks_by_tier bottom_term]]

  set eligible_upper [expr {$upper_inst_count > 0 && $upper_term_count == 0}]
  set eligible_bottom [expr {$bottom_inst_count > 0 && $bottom_term_count == 0}]

  if {$eligible_upper && $eligible_bottom} {
    if {$upper_inst_count >= $bottom_inst_count} {
      return [list upper ""]
    }
    return [list bottom ""]
  }
  if {$eligible_upper} {
    return [list upper ""]
  }
  if {$eligible_bottom} {
    return [list bottom ""]
  }

  if {$upper_inst_count == 0 && $bottom_inst_count == 0 && ($upper_term_count > 0 || $bottom_term_count > 0)} {
    return [list "" "top_level_sink_rewire_not_supported"]
  }
  return [list "" "top_level_sink_rewire_not_supported"]
}

proc ::tier_split_or2::sanitize_name_component {name} {
  regsub -all {[^A-Za-z0-9_]} $name "_" clean_name
  return $clean_name
}

proc ::tier_split_or2::existing_names {block} {
  set names {}
  foreach net [$block getNets] {
    lappend names [$net getName]
  }
  foreach inst [$block getInsts] {
    lappend names [$inst getName]
  }
  return $names
}

proc ::tier_split_or2::ensure_unique_name {block base_name} {
  set names [::tier_split_or2::existing_names $block]
  set name $base_name
  set idx 0
  while {[lsearch -exact $names $name] >= 0} {
    incr idx
    set name "${base_name}_${idx}"
  }
  return $name
}

proc ::tier_split_or2::anchor_inst_for_move {driver_iterm moved_inst_sinks} {
  if {[llength $moved_inst_sinks] > 0} {
    return [[lindex $moved_inst_sinks 0] getInst]
  }
  return [$driver_iterm getInst]
}

proc ::tier_split_or2::split_net_with_buffer {block net driver_info sinks_by_tier fp} {
  variable CFG

  set net_name [$net getName]
  lassign $driver_info driver_kind driver_obj
  if {$driver_kind ne "iterm"} {
    puts $fp "SKIP $net_name reason=top_level_term_driver_not_supported"
    return [list 0 "top_level_term_driver_not_supported"]
  }

  set upper_inst_sinks [dict get $sinks_by_tier upper_inst]
  set bottom_inst_sinks [dict get $sinks_by_tier bottom_inst]
  set upper_term_sinks [dict get $sinks_by_tier upper_term]
  set bottom_term_sinks [dict get $sinks_by_tier bottom_term]

  lassign [::tier_split_or2::choose_buffer_tier $sinks_by_tier] buffer_tier tier_reason
  if {$buffer_tier eq ""} {
    puts $fp "SKIP $net_name reason=$tier_reason"
    return [list 0 $tier_reason]
  }

  set moved_inst_sinks {}
  set moved_term_sinks {}
  set retained_tier ""
  if {$buffer_tier eq "upper"} {
    set moved_inst_sinks $upper_inst_sinks
    set moved_term_sinks $upper_term_sinks
    set retained_tier bottom
  } else {
    set moved_inst_sinks $bottom_inst_sinks
    set moved_term_sinks $bottom_term_sinks
    set retained_tier upper
  }

  if {[llength $moved_inst_sinks] == 0 && [llength $moved_term_sinks] == 0} {
    puts $fp "SKIP $net_name reason=no_sinks_on_selected_buffer_tier buffer_tier=$buffer_tier"
    return [list 0 "no_sinks_on_selected_buffer_tier"]
  }
  if {[llength $moved_term_sinks] > 0} {
    puts $fp "SKIP $net_name reason=top_level_sink_rewire_not_supported buffer_tier=$buffer_tier"
    return [list 0 "top_level_sink_rewire_not_supported"]
  }

  set buffer_info [::tier_split_or2::choose_buffer_master $buffer_tier]
  if {$buffer_info eq ""} {
    puts $fp "SKIP $net_name reason=no_tier_buffer_master buffer_tier=$buffer_tier"
    return [list 0 "no_tier_buffer_master"]
  }
  lassign $buffer_info buffer_master_name buffer_in_pin buffer_out_pin
  set buffer_master [::tier_split_or2::find_master_by_name $buffer_master_name]
  if {$buffer_master eq ""} {
    puts $fp "SKIP $net_name reason=buffer_master_lookup_failed buffer_master=$buffer_master_name"
    return [list 0 "buffer_master_lookup_failed"]
  }

  set safe_net_name [::tier_split_or2::sanitize_name_component $net_name]
  set inst_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(buffer_inst_suffix)_${buffer_tier}"]
  set branch_net_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(branch_net_suffix)_${buffer_tier}"]

  puts $fp "ACTION net=$net_name driver=[::tier_split_or2::object_label $driver_kind $driver_obj] buffer_master=$buffer_master_name buffer_tier=$buffer_tier retained_tier=$retained_tier new_inst=$inst_name new_net=$branch_net_name"

  if {$CFG(dry_run)} {
    foreach sink $moved_inst_sinks {
      puts $fp "  DRYRUN MOVE [::tier_split_or2::iterm_full_name $sink] -> $branch_net_name"
    }
    return [list 1 ""]
  }

  set buffer_inst [odb::dbInst_create $block $buffer_master $inst_name]
  if {$buffer_inst eq "" || $buffer_inst eq "NULL"} {
    puts $fp "SKIP $net_name reason=dbInst_create_failed buffer_master=$buffer_master_name"
    return [list 0 "dbInst_create_failed"]
  }

  set anchor_inst [::tier_split_or2::anchor_inst_for_move $driver_obj $moved_inst_sinks]
  set anchor_loc [$anchor_inst getLocation]
  $buffer_inst setLocation [lindex $anchor_loc 0] [lindex $anchor_loc 1]
  catch {$buffer_inst setOrient [$anchor_inst getOrient]}
  catch {$buffer_inst setPlacementStatus [$anchor_inst getPlacementStatus]}

  set branch_net [odb::dbNet_create $block $branch_net_name]
  if {$branch_net eq "" || $branch_net eq "NULL"} {
    puts $fp "SKIP $net_name reason=dbNet_create_failed new_net=$branch_net_name"
    return [list 0 "dbNet_create_failed"]
  }

  set buffer_in_it [$buffer_inst findITerm $buffer_in_pin]
  set buffer_out_it [$buffer_inst findITerm $buffer_out_pin]
  if {$buffer_in_it eq "" || $buffer_out_it eq ""} {
    puts $fp "SKIP $net_name reason=buffer_pin_lookup_failed buffer_master=$buffer_master_name"
    return [list 0 "buffer_pin_lookup_failed"]
  }

  $buffer_in_it connect $net
  $buffer_out_it connect $branch_net

  foreach sink $moved_inst_sinks {
    $sink connect $branch_net
    puts $fp "  MOVE SINK [::tier_split_or2::iterm_full_name $sink] -> $branch_net_name"
  }

  return [list 1 ""]
}

proc ::tier_split_or2::run {} {
  variable CFG
  set block [ord::get_db_block]
  set fp [open $CFG(report_file) w]

  puts $fp "# tier_split_or2"
  puts $fp "# mode=regular_buffer_split"
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
    foreach iterm [$inst getITerms] {
      puts $fp "PIN [::tier_split_or2::iterm_full_name $iterm] [::tier_split_or2::classify_iterm $iterm]"
    }
  }
  puts $fp ""

  puts $fp "## NET_ACTIONS"

  set split_cnt 0
  set skip_cnt 0
  set mixed_tier_nets 0
  set candidate_nets 0
  array set skip_reason_counts {}

  foreach net [$block getNets] {
    set net_name [$net getName]
    set upper_sinks {}
    set bottom_sinks {}

    set sinks_by_tier [::tier_split_or2::collect_sinks_by_tier $net]
    set upper_total [expr {[llength [dict get $sinks_by_tier upper_inst]] + [llength [dict get $sinks_by_tier upper_term]]}]
    set bottom_total [expr {[llength [dict get $sinks_by_tier bottom_inst]] + [llength [dict get $sinks_by_tier bottom_term]]}]

    if {$CFG(require_both_sink_tiers)} {
      if {$upper_total == 0 || $bottom_total == 0} {
        continue
      }
    }
    incr mixed_tier_nets

    lassign [::tier_split_or2::get_net_driver $net] driver_info driver_reason
    if {$driver_info eq ""} {
      puts $fp "SKIP $net_name reason=$driver_reason"
      incr skip_cnt
      if {![info exists skip_reason_counts($driver_reason)]} {
        set skip_reason_counts($driver_reason) 0
      }
      incr skip_reason_counts($driver_reason)
      continue
    }
    incr candidate_nets

    lassign [::tier_split_or2::split_net_with_buffer $block $net $driver_info $sinks_by_tier $fp] split_ok split_reason
    if {$split_ok} {
      incr split_cnt
    } else {
      incr skip_cnt
      if {$split_reason ne ""} {
        if {![info exists skip_reason_counts($split_reason)]} {
          set skip_reason_counts($split_reason) 0
        }
        incr skip_reason_counts($split_reason)
      }
    }
  }

  puts $fp ""
  puts $fp "# split_count=$split_cnt"
  puts $fp "# skip_count=$skip_cnt"
  puts $fp "# mixed_tier_nets=$mixed_tier_nets"
  puts $fp "# candidate_nets=$candidate_nets"
  puts $fp "# processed_residual=[expr {$candidate_nets - $split_cnt}]"
  if {[array size skip_reason_counts] > 0} {
    puts $fp "# skip_reasons"
    foreach reason [lsort [array names skip_reason_counts]] {
      puts $fp "#   $reason $skip_reason_counts($reason)"
    }
  }
  close $fp

  puts "tier_split_or2: wrote $CFG(report_file)"
  puts "tier_split_or2: split_count=$split_cnt skip_count=$skip_cnt mixed_tier_nets=$mixed_tier_nets candidate_nets=$candidate_nets dry_run=$CFG(dry_run)"
  return [dict create \
    split_count $split_cnt \
    skip_count $skip_cnt \
    mixed_tier_nets $mixed_tier_nets \
    candidate_nets $candidate_nets \
    processed_residual [expr {$candidate_nets - $split_cnt}] \
    dry_run $CFG(dry_run) \
    report_file $CFG(report_file) \
    skip_reason_counts [array get skip_reason_counts]]
}
