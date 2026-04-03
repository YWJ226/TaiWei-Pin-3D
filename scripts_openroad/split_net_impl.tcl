# ============================================================
# split_net_impl.tcl
# Implementation split out from split_net.tcl to keep stage source files lighter.
# ============================================================

proc ::tier_split_or2::iterm_name_list {iterms} {
  set out {}
  foreach iterm $iterms {
    lappend out [::tier_split_or2::iterm_full_name $iterm]
  }
  return [lsort -unique $out]
}

proc ::tier_split_or2::cleanup_failed_split {net moved_inst_sinks branch_net_name buffer_inst_name} {
  foreach sink $moved_inst_sinks {
    catch {$sink connect $net}
  }
  if {$buffer_inst_name ne ""} {
    catch {delete_instance $buffer_inst_name}
  }
  if {$branch_net_name ne ""} {
    set branch_net [_pin3d_find_net_by_name $branch_net_name]
    if {$branch_net ne "" && $branch_net ne "NULL"} {
      catch {::odb::dbNet_destroy $branch_net}
    }
  }
}

proc ::tier_split_or2::build_split_record {net driver_iterm buffer_tier retained_tier buffer_master_name buffer_inst_name branch_net_name moved_inst_sinks retained_inst_sinks} {
  set driver_tier [::tier_split_or2::classify_iterm $driver_iterm]
  return [dict create \
    original_net [$net getName] \
    branch_net $branch_net_name \
    split_inst $buffer_inst_name \
    buffer_master $buffer_master_name \
    driver_tier $driver_tier \
    buffer_tier $buffer_tier \
    retained_tier $retained_tier \
    driver_pin [::tier_split_or2::iterm_full_name $driver_iterm] \
    moved_sinks [::tier_split_or2::iterm_name_list $moved_inst_sinks] \
    retained_sinks [::tier_split_or2::iterm_name_list $retained_inst_sinks]]
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
  variable INST_TIER_CACHE
  set name [$inst getName]
  if {[info exists INST_TIER_CACHE($name)]} {
    return $INST_TIER_CACHE($name)
  }

  if {[llength [info commands _or_inst_tier]]} {
    set canonical_tier [_or_inst_tier $inst]
    if {$canonical_tier eq "split_buffer"} {
      set INST_TIER_CACHE($name) $canonical_tier
      return $canonical_tier
    }
    if {$canonical_tier eq "upper" || $canonical_tier eq "bottom"} {
      set INST_TIER_CACHE($name) $canonical_tier
      return $canonical_tier
    }
  }

  if {[::tier_split_or2::name_matches_any $name $CFG(upper_inst_re)]} {
    set INST_TIER_CACHE($name) upper
    return upper
  }
  if {[::tier_split_or2::name_matches_any $name $CFG(lower_inst_re)]} {
    set INST_TIER_CACHE($name) bottom
    return bottom
  }

  if {$CFG(use_bbox_split)} {
    if {[::tier_split_or2::inst_center_y_dbu $inst] >= [::tier_split_or2::split_y_dbu]} {
      set INST_TIER_CACHE($name) upper
      return upper
    }
    set INST_TIER_CACHE($name) bottom
    return bottom
  }
  set INST_TIER_CACHE($name) unknown
  return unknown
}

proc ::tier_split_or2::iterm_full_name {iterm} {
  return "[[$iterm getInst] getName]/[[$iterm getMTerm] getName]"
}

proc ::tier_split_or2::classify_iterm {iterm} {
  variable CFG
  set full [::tier_split_or2::iterm_full_name $iterm]
  variable ITERM_TIER_CACHE
  if {[info exists ITERM_TIER_CACHE($full)]} {
    return $ITERM_TIER_CACHE($full)
  }

  if {[::tier_split_or2::name_matches_any $full $CFG(upper_pin_re)]} {
    set ITERM_TIER_CACHE($full) upper
    return upper
  }
  if {[::tier_split_or2::name_matches_any $full $CFG(lower_pin_re)]} {
    set ITERM_TIER_CACHE($full) bottom
    return bottom
  }
  set tier [::tier_split_or2::classify_inst [$iterm getInst]]
  set ITERM_TIER_CACHE($full) $tier
  return $tier
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
  variable BTERM_TIER_CACHE
  set name [$bterm getName]
  if {[info exists BTERM_TIER_CACHE($name)]} {
    return $BTERM_TIER_CACHE($name)
  }
  if {[llength [info commands _or_bterm_tier]]} {
    set tier [_or_bterm_tier $bterm]
    set BTERM_TIER_CACHE($name) $tier
    return $tier
  }
  set BTERM_TIER_CACHE($name) unknown
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
  variable MASTER_LOOKUP
  if {[info exists MASTER_LOOKUP($master_name)]} {
    return $MASTER_LOOKUP($master_name)
  }
  set db [ord::get_db]
  foreach lib [::odb::dbDatabase_getLibs $db] {
    foreach master [::odb::dbLib_getMasters $lib] {
      if {[$master getName] eq $master_name} {
        set MASTER_LOOKUP($master_name) $master
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

proc ::tier_split_or2::next_power_of_two {value} {
  if {$value <= 1} {
    return 1
  }
  set power 1
  while {$power < $value} {
    set power [expr {$power * 2}]
  }
  return $power
}

proc ::tier_split_or2::required_buffer_drive_score {moved_sink_count} {
  set per_drive_unit 24
  if {[info exists ::env(PIN3D_SPLIT_FANOUT_PER_DRIVE)] && $::env(PIN3D_SPLIT_FANOUT_PER_DRIVE) ne ""} {
    set per_drive_unit $::env(PIN3D_SPLIT_FANOUT_PER_DRIVE)
  }
  if {$per_drive_unit < 1} {
    set per_drive_unit 24
  }

  set units [expr {int(ceil(double(max($moved_sink_count, 1)) / double($per_drive_unit)))}]
  return [::tier_split_or2::next_power_of_two $units]
}

proc ::tier_split_or2::opposite_tier {tier} {
  switch -- $tier {
    upper {
      return bottom
    }
    bottom {
      return upper
    }
    default {
      return unknown
    }
  }
}

proc ::tier_split_or2::choose_buffer_master {tier moved_sink_count} {
  variable CFG
  variable BUFFER_MASTER_CHOICES
  if {![info exists BUFFER_MASTER_CHOICES($tier)]} {
    set candidates {}
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
          lappend candidates [list [::tier_split_or2::buffer_drive_score $master_name] $master_name $input_term $output_term]
        }
      }
    }
    set BUFFER_MASTER_CHOICES($tier) [lsort -integer -index 0 [lsort -dictionary -index 1 $candidates]]
  }

  set sorted $BUFFER_MASTER_CHOICES($tier)
  if {[llength $sorted] == 0} {
    return ""
  }
  set required_drive [::tier_split_or2::required_buffer_drive_score $moved_sink_count]
  foreach item $sorted {
    if {[lindex $item 0] >= $required_drive} {
      return [concat [lrange $item 1 end] [list [lindex $item 0] $required_drive]]
    }
  }
  set largest [lindex $sorted end]
  return [concat [lrange $largest 1 end] [list [lindex $largest 0] $required_drive]]
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
      split_buffer {
        continue
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

proc ::tier_split_or2::choose_buffer_tier {driver_tier upper_inst_count bottom_inst_count} {
  set opposite_tier [::tier_split_or2::opposite_tier $driver_tier]
  switch -- $opposite_tier {
    upper {
      if {$upper_inst_count > 0} {
        return [list upper opposite_driver_tier]
      }
      return [list "" no_supported_upper_instance_sinks]
    }
    bottom {
      if {$bottom_inst_count > 0} {
        return [list bottom opposite_driver_tier]
      }
      return [list "" no_supported_bottom_instance_sinks]
    }
    default {
      return [list "" driver_tier_unknown]
    }
  }
}

proc ::tier_split_or2::sanitize_name_component {name} {
  regsub -all {[^A-Za-z0-9_]} $name "_" clean_name
  return $clean_name
}

proc ::tier_split_or2::init_existing_names {block} {
  variable NAME_SET
  array unset NAME_SET
  foreach net [$block getNets] {
    set NAME_SET([$net getName]) 1
  }
  foreach inst [$block getInsts] {
    set NAME_SET([$inst getName]) 1
  }
}

proc ::tier_split_or2::ensure_unique_name {block base_name} {
  variable NAME_SET
  set name $base_name
  set idx 0
  while {[info exists NAME_SET($name)]} {
    incr idx
    set name "${base_name}_${idx}"
  }
  set NAME_SET($name) 1
  return $name
}

proc ::tier_split_or2::remember_created_split_objects {buffer_inst branch_net buffer_in_it buffer_out_it moved_inst_sinks} {
  set ::_PIN3D_INST_CACHE([$buffer_inst getName]) $buffer_inst
  set ::_PIN3D_NET_CACHE([$branch_net getName]) $branch_net
  set ::_PIN3D_ITERM_CACHE([::tier_split_or2::iterm_full_name $buffer_in_it]) $buffer_in_it
  set ::_PIN3D_ITERM_CACHE([::tier_split_or2::iterm_full_name $buffer_out_it]) $buffer_out_it
  foreach sink $moved_inst_sinks {
    set ::_PIN3D_ITERM_CACHE([::tier_split_or2::iterm_full_name $sink]) $sink
  }
}

proc ::tier_split_or2::fast_verify_inserted_split {net driver_obj buffer_in_it buffer_out_it branch_net moved_inst_sinks retained_inst_sinks} {
  if {[_pin3d_iterm_net $buffer_in_it] ne $net} {
    return [dict create status violated reason buffer_input_not_on_original_net]
  }
  if {[_pin3d_iterm_net $buffer_out_it] ne $branch_net} {
    return [dict create status violated reason buffer_output_not_on_branch_net]
  }
  foreach sink $moved_inst_sinks {
    if {[_pin3d_iterm_net $sink] ne $branch_net} {
      return [dict create status violated reason moved_sink_not_on_branch_net]
    }
  }
  foreach sink $retained_inst_sinks {
    if {[_pin3d_iterm_net $sink] eq $branch_net} {
      return [dict create status violated reason retained_sink_leaked_to_branch_net]
    }
  }
  if {[_pin3d_iterm_net $driver_obj] ne $net} {
    return [dict create status violated reason driver_not_on_original_net]
  }
  if {[net_has_mixed_fanout $net]} {
    return [dict create status violated reason original_net_still_mixed_fanout]
  }
  if {[net_has_mixed_fanout $branch_net]} {
    return [dict create status violated reason branch_net_still_mixed_fanout]
  }
  return [dict create status valid reason direct_split_insert_ok]
}

proc ::tier_split_or2::record_skip {fp net_name reason details} {
  variable CFG
  if {!$CFG(log_skip_details)} {
    return
  }
  if {$details eq ""} {
    puts $fp "SKIP $net_name reason=$reason"
  } else {
    puts $fp "SKIP $net_name reason=$reason $details"
  }
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
    ::tier_split_or2::record_skip $fp $net_name "top_level_term_driver_not_supported" ""
    return [list 0 "top_level_term_driver_not_supported"]
  }

  set upper_inst_sinks [dict get $sinks_by_tier upper_inst]
  set bottom_inst_sinks [dict get $sinks_by_tier bottom_inst]
  set upper_term_sinks [dict get $sinks_by_tier upper_term]
  set bottom_term_sinks [dict get $sinks_by_tier bottom_term]

  set driver_tier [::tier_split_or2::classify_iterm $driver_obj]
  set upper_inst_count [llength $upper_inst_sinks]
  set bottom_inst_count [llength $bottom_inst_sinks]
  lassign [::tier_split_or2::choose_buffer_tier $driver_tier $upper_inst_count $bottom_inst_count] buffer_tier tier_reason
  if {$buffer_tier eq ""} {
    ::tier_split_or2::record_skip $fp $net_name $tier_reason "driver_tier=$driver_tier"
    return [list 0 $tier_reason ""]
  }

  set moved_inst_sinks {}
  set moved_term_sinks {}
  set retained_tier ""
  if {$buffer_tier eq "upper"} {
    set moved_inst_sinks $upper_inst_sinks
    set moved_term_sinks $upper_term_sinks
    set retained_inst_sinks $bottom_inst_sinks
    set retained_tier bottom
  } else {
    set moved_inst_sinks $bottom_inst_sinks
    set moved_term_sinks $bottom_term_sinks
    set retained_inst_sinks $upper_inst_sinks
    set retained_tier upper
  }

  if {[llength $moved_inst_sinks] == 0 && [llength $moved_term_sinks] == 0} {
    ::tier_split_or2::record_skip $fp $net_name "no_sinks_on_selected_buffer_tier" "buffer_tier=$buffer_tier"
    return [list 0 "no_sinks_on_selected_buffer_tier"]
  }
  if {[llength $moved_term_sinks] > 0} {
    ::tier_split_or2::record_skip $fp $net_name "top_level_sink_rewire_not_supported" "buffer_tier=$buffer_tier"
    return [list 0 "top_level_sink_rewire_not_supported"]
  }

  set moved_sink_count [expr {[llength $moved_inst_sinks] + [llength $moved_term_sinks]}]
  set buffer_info [::tier_split_or2::choose_buffer_master $buffer_tier $moved_sink_count]
  if {$buffer_info eq ""} {
    ::tier_split_or2::record_skip $fp $net_name "no_tier_buffer_master" "buffer_tier=$buffer_tier"
    return [list 0 "no_tier_buffer_master"]
  }
  lassign $buffer_info buffer_master_name buffer_in_pin buffer_out_pin chosen_drive required_drive
  set buffer_master [::tier_split_or2::find_master_by_name $buffer_master_name]
  if {$buffer_master eq ""} {
    ::tier_split_or2::record_skip $fp $net_name "buffer_master_lookup_failed" "buffer_master=$buffer_master_name"
    return [list 0 "buffer_master_lookup_failed"]
  }

  set safe_net_name [::tier_split_or2::sanitize_name_component $net_name]
  set inst_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(buffer_inst_suffix)_${buffer_tier}"]
  set branch_net_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(branch_net_suffix)_${buffer_tier}"]

  puts $fp "ACTION net=$net_name driver=[::tier_split_or2::object_label $driver_kind $driver_obj] driver_tier=$driver_tier selection=$tier_reason buffer_master=$buffer_master_name buffer_tier=$buffer_tier retained_tier=$retained_tier moved_sink_count=$moved_sink_count chosen_drive=$chosen_drive required_drive=$required_drive new_inst=$inst_name new_net=$branch_net_name"

  if {$CFG(dry_run)} {
    foreach sink $moved_inst_sinks {
      puts $fp "  DRYRUN MOVE [::tier_split_or2::iterm_full_name $sink] -> $branch_net_name"
    }
    set dry_record [::tier_split_or2::build_split_record $net $driver_obj $buffer_tier $retained_tier $buffer_master_name $inst_name $branch_net_name $moved_inst_sinks $retained_inst_sinks]
    return [list 1 "" $dry_record]
  }

  set buffer_inst [odb::dbInst_create $block $buffer_master $inst_name]
  if {$buffer_inst eq "" || $buffer_inst eq "NULL"} {
    ::tier_split_or2::record_skip $fp $net_name "dbInst_create_failed" "buffer_master=$buffer_master_name"
    return [list 0 "dbInst_create_failed" ""]
  }

  set anchor_inst [::tier_split_or2::anchor_inst_for_move $driver_obj $moved_inst_sinks]
  set anchor_loc [$anchor_inst getLocation]
  $buffer_inst setLocation [lindex $anchor_loc 0] [lindex $anchor_loc 1]
  catch {$buffer_inst setOrient [$anchor_inst getOrient]}
  catch {$buffer_inst setPlacementStatus [$anchor_inst getPlacementStatus]}

  set branch_net [odb::dbNet_create $block $branch_net_name]
  if {$branch_net eq "" || $branch_net eq "NULL"} {
    ::tier_split_or2::record_skip $fp $net_name "dbNet_create_failed" "new_net=$branch_net_name"
    catch {delete_instance $inst_name}
    return [list 0 "dbNet_create_failed" ""]
  }

  set buffer_in_it [$buffer_inst findITerm $buffer_in_pin]
  set buffer_out_it [$buffer_inst findITerm $buffer_out_pin]
  if {$buffer_in_it eq "" || $buffer_out_it eq ""} {
    ::tier_split_or2::record_skip $fp $net_name "buffer_pin_lookup_failed" "buffer_master=$buffer_master_name"
    catch {delete_instance $inst_name}
    catch {::odb::dbNet_destroy $branch_net}
    return [list 0 "buffer_pin_lookup_failed" ""]
  }

  $buffer_in_it connect $net
  $buffer_out_it connect $branch_net

  foreach sink $moved_inst_sinks {
    $sink connect $branch_net
    puts $fp "  MOVE SINK [::tier_split_or2::iterm_full_name $sink] -> $branch_net_name"
  }

  ::tier_split_or2::remember_created_split_objects $buffer_inst $branch_net $buffer_in_it $buffer_out_it $moved_inst_sinks
  set record [::tier_split_or2::build_split_record $net $driver_obj $buffer_tier $retained_tier $buffer_master_name $inst_name $branch_net_name $moved_inst_sinks $retained_inst_sinks]
  set verify_status [::tier_split_or2::fast_verify_inserted_split $net $driver_obj $buffer_in_it $buffer_out_it $branch_net $moved_inst_sinks $retained_inst_sinks]
  set verify_state [dict get $verify_status status]
  if {$verify_state ne "valid"} {
    puts $fp "  VERIFY_FAIL status=$verify_state reason=[dict get $verify_status reason]"
    ::tier_split_or2::cleanup_failed_split $net $moved_inst_sinks $branch_net_name $inst_name
    return [list 0 "verify_[dict get $verify_status reason]" ""]
  }

  puts $fp "  VERIFY_OK status=$verify_state"
  return [list 1 "" $record]
}

proc ::tier_split_or2::run {} {
  variable CFG
  variable INST_TIER_CACHE
  variable ITERM_TIER_CACHE
  variable BTERM_TIER_CACHE
  set block [ord::get_db_block]
  _pin3d_rebuild_name_caches
  array unset INST_TIER_CACHE
  array unset ITERM_TIER_CACHE
  array unset BTERM_TIER_CACHE
  set fp [open $CFG(report_file) w]

  puts $fp "# tier_split_or2"
  puts $fp "# mode=regular_buffer_split"
  puts $fp "# dry_run=$CFG(dry_run)"
  puts $fp "# split_y_um=$CFG(split_y_um)"
  puts $fp ""

  if {$CFG(dump_cell_tier)} {
    puts $fp "## CELL_TIER"
    foreach inst [$block getInsts] {
      puts $fp "CELL [$inst getName] [::tier_split_or2::classify_inst $inst]"
    }
    puts $fp ""
  }
  if {$CFG(dump_pin_tier)} {
    puts $fp "## PIN_TIER"
    foreach inst [$block getInsts] {
      foreach iterm [$inst getITerms] {
        puts $fp "PIN [::tier_split_or2::iterm_full_name $iterm] [::tier_split_or2::classify_iterm $iterm]"
      }
    }
    puts $fp ""
  }

  puts $fp "## NET_ACTIONS"

  set split_cnt 0
  set skip_cnt 0
  set mixed_tier_nets 0
  set candidate_nets 0
  set manifest_records {}
  array set skip_reason_counts {}
  array set clock_net_lookup {}
  if {$CFG(skip_clock_nets)} {
    foreach clock_net_name [_clock_net_name_set] {
      set clock_net_lookup($clock_net_name) 1
    }
  }

  set original_net_names {}
  ::tier_split_or2::init_existing_names $block
  foreach net [$block getNets] {
    lappend original_net_names [$net getName]
  }

  foreach net_name $original_net_names {
    set net [_pin3d_find_net_by_name $net_name]
    if {$net eq "" || $net eq "NULL"} {
      continue
    }
    if {[_split_branch_name_match $net_name] || [_net_touches_split_buffer_inst $net]} {
      ::tier_split_or2::record_skip $fp $net_name "split_generated_net" ""
      incr skip_cnt
      if {![info exists skip_reason_counts(split_generated_net)]} {
        set skip_reason_counts(split_generated_net) 0
      }
      incr skip_reason_counts(split_generated_net)
      continue
    }
    if {$CFG(skip_clock_nets) && [info exists clock_net_lookup($net_name)]} {
      ::tier_split_or2::record_skip $fp $net_name "clock_net" ""
      incr skip_cnt
      if {![info exists skip_reason_counts(clock_net)]} {
        set skip_reason_counts(clock_net) 0
      }
      incr skip_reason_counts(clock_net)
      continue
    }

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
      ::tier_split_or2::record_skip $fp $net_name $driver_reason ""
      incr skip_cnt
      if {![info exists skip_reason_counts($driver_reason)]} {
        set skip_reason_counts($driver_reason) 0
      }
      incr skip_reason_counts($driver_reason)
      continue
    }
    incr candidate_nets

    lassign [::tier_split_or2::split_net_with_buffer $block $net $driver_info $sinks_by_tier $fp] split_ok split_reason split_record
    if {$split_ok} {
      incr split_cnt
      if {$split_record ne ""} {
        lappend manifest_records $split_record
      }
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

  if {$CFG(manifest_file) ne ""} {
    pin3d_write_split_manifest $manifest_records $CFG(manifest_file)
  }

  puts $fp ""
  puts $fp "# split_count=$split_cnt"
  puts $fp "# skip_count=$skip_cnt"
  puts $fp "# mixed_tier_nets=$mixed_tier_nets"
  puts $fp "# mixed_fanout_nets=$mixed_tier_nets"
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
    manifest_records $manifest_records \
    manifest_file $CFG(manifest_file) \
    dry_run $CFG(dry_run) \
    report_file $CFG(report_file) \
    skip_reason_counts [array get skip_reason_counts]]
}
