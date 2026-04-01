# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# split_net.tcl
# Regular-buffer split pass for mixed-tier signal nets.
# This pass is intended to run after IO placement and before macro placement.
# It rewrites eligible mixed-tier nets so that each successfully processed net
# becomes tier-pure:
#   driver -> original_net -> retained sinks + buffer input
#   buffer -> branch_net   -> moved sinks
# ============================================================

source $::env(CADENCE_SCRIPTS_DIR)/tier_classification.tcl

namespace eval ::mixed_tier_split {
  variable CFG
  array set CFG {
    report_file          mixed_tier_split.summary.rpt
    action_file          mixed_tier_split.actions.rpt
    dry_run              0
    run_eco_place        0
    verify_processed     1
    net_prefix           SPLITNET
    inst_prefix          SPLITBUF
  }

  variable COUNTERS
  array set COUNTERS {
    candidate_nets       0
    mixed_nets           0
    split_nets           0
    skipped_nets         0
    processed_residual   0
    io_upper             0
    io_bottom            0
  }

  variable SKIP_REASONS
  array set SKIP_REASONS {}

  variable PROCESSED_NETS {}
}

proc ::mixed_tier_split::box_flat4 {box} {
  if {[llength $box] == 1} {
    set box [lindex $box 0]
  }
  if {[llength $box] == 2 && [llength [lindex $box 0]] == 2} {
    set ll [lindex $box 0]
    set ur [lindex $box 1]
    return [list [lindex $ll 0] [lindex $ll 1] [lindex $ur 0] [lindex $ur 1]]
  }
  return $box
}

proc ::mixed_tier_split::split_inst_term_name {full_name} {
  set idx [string last "/" $full_name]
  if {$idx < 0} {
    return [list "" $full_name]
  }
  return [list [string range $full_name 0 [expr {$idx - 1}]] [string range $full_name [expr {$idx + 1}] end]]
}

proc ::mixed_tier_split::term_role {term_ptr} {
  if {[dbGet $term_ptr.isInput]} {
    return "driver"
  }
  if {[dbGet $term_ptr.isOutput]} {
    return "sink"
  }
  return "unsupported"
}

proc ::mixed_tier_split::inst_term_role {inst_term_ptr} {
  if {[dbGet $inst_term_ptr.isOutput]} {
    return "driver"
  }
  if {[dbGet $inst_term_ptr.isInput]} {
    return "sink"
  }
  return "unsupported"
}

proc ::mixed_tier_split::record_skip {reason} {
  variable COUNTERS
  variable SKIP_REASONS
  incr COUNTERS(skipped_nets)
  if {![info exists SKIP_REASONS($reason)]} {
    set SKIP_REASONS($reason) 0
  }
  incr SKIP_REASONS($reason)
}

proc ::mixed_tier_split::is_candidate_net {net_ptr} {
  if {[dbGet $net_ptr.isPwrOrGnd]} {
    return [list 0 "pg_net"]
  }
  if {[llength [info commands _report_is_clock_net_ptr]] && [_report_is_clock_net_ptr $net_ptr]} {
    return [list 0 "clock_net"]
  }
  if {[catch {dbGet $net_ptr.isClock} is_clock] == 0 && $is_clock} {
    return [list 0 "clock_net"]
  }
  if {[catch {dbGet $net_ptr.isSpecial} is_special] == 0 && $is_special} {
    return [list 0 "special_net"]
  }

  return [list 1 ""]
}

proc ::mixed_tier_split::get_net_driver {net_ptr} {
  set drivers {}

  foreach inst_term [dbGet -e $net_ptr.instTerms] {
    if {[::mixed_tier_split::inst_term_role $inst_term] eq "driver"} {
      lappend drivers $inst_term
    }
  }
  foreach term [dbGet -e $net_ptr.terms] {
    if {[::mixed_tier_split::term_role $term] eq "driver"} {
      lappend drivers $term
    }
  }

  if {[llength $drivers] != 1} {
    return [list "" "driver_count_[llength $drivers]"]
  }
  return [list [lindex $drivers 0] ""]
}

proc ::mixed_tier_split::collect_sinks_by_tier {net_ptr} {
  set upper_inst_sinks {}
  set bottom_inst_sinks {}
  set upper_term_sinks {}
  set bottom_term_sinks {}
  set unknown_sinks {}

  foreach inst_term [dbGet -e $net_ptr.instTerms] {
    if {[::mixed_tier_split::inst_term_role $inst_term] ne "sink"} {
      continue
    }
    switch -- [tier_classify_inst_term_ptr $inst_term] {
      upper {
        lappend upper_inst_sinks $inst_term
      }
      bottom {
        lappend bottom_inst_sinks $inst_term
      }
      split_buffer {
        continue
      }
      default {
        lappend unknown_sinks $inst_term
      }
    }
  }

  foreach term [dbGet -e $net_ptr.terms] {
    if {[::mixed_tier_split::term_role $term] ne "sink"} {
      continue
    }
    switch -- [tier_classify_term_ptr $term] {
      upper {
        lappend upper_term_sinks $term
      }
      bottom {
        lappend bottom_term_sinks $term
      }
      default {
        lappend unknown_sinks $term
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

proc ::mixed_tier_split::choose_buffer_tier {upper_count bottom_count} {
  if {$upper_count >= $bottom_count} {
    return "upper"
  }
  return "bottom"
}

proc ::mixed_tier_split::master_io_summary {master_name} {
  set cell_ptr [dbGet -p head.libCells.name $master_name]
  if {$cell_ptr eq "0x0"} {
    return [list -1 -1 "" ""]
  }

  set in_cnt 0
  set out_cnt 0
  set in_term ""
  set out_term ""

  foreach term [dbGet $cell_ptr.terms] {
    if {[dbGet $term.isInput]} {
      incr in_cnt
      set in_term [dbGet $term.name]
    } elseif {[dbGet $term.isOutput]} {
      incr out_cnt
      set out_term [dbGet $term.name]
    }
  }

  return [list $in_cnt $out_cnt $in_term $out_term]
}

proc ::mixed_tier_split::choose_buffer_master {tier} {
  set preferred [format "BUF_X1_%s" $tier]
  foreach candidate [concat [list $preferred] [dbGet head.libCells.name]] {
    if {$candidate eq ""} {
      continue
    }
    if {![string match "BUF*_${tier}" $candidate]} {
      continue
    }
    if {[string match "CLKBUF*_${tier}" $candidate] || [string match "TBUF*_${tier}" $candidate]} {
      continue
    }

    lassign [::mixed_tier_split::master_io_summary $candidate] in_cnt out_cnt in_term out_term
    if {$in_cnt == 1 && $out_cnt == 1 && $in_term ne "" && $out_term ne ""} {
      return [list $candidate $in_term $out_term]
    }
  }
  return ""
}

proc ::mixed_tier_split::object_label {obj_ptr} {
  set obj_type [dbGet $obj_ptr.objType]
  if {$obj_type eq "instTerm"} {
    return [dbGet $obj_ptr.name]
  }
  return [dbGet $obj_ptr.name]
}

proc ::mixed_tier_split::ensure_unique_name {base existing_names} {
  set name $base
  set idx 0
  while {[lsearch -exact $existing_names $name] >= 0 || [dbGet -e [dbGet -p top.nets.name $name]] ne "" || [dbGet -e [dbGet -p top.insts.name $name]] ne ""} {
    incr idx
    set name "${base}_${idx}"
  }
  return $name
}

proc ::mixed_tier_split::sanitize_name_component {name} {
  regsub -all {[^A-Za-z0-9_]} $name "_" clean_name
  return $clean_name
}

proc ::mixed_tier_split::normalize_object_name {name} {
  if {[string length $name] >= 2 && [string index $name 0] eq "{" && [string index $name end] eq "}"} {
    return [string range $name 1 end-1]
  }
  return $name
}

proc ::mixed_tier_split::inst_term_names {inst_terms} {
  set names {}
  foreach inst_term $inst_terms {
    lappend names [::mixed_tier_split::normalize_object_name [dbGet $inst_term.name]]
  }
  return $names
}

proc ::mixed_tier_split::split_net_with_buffer {net_ptr driver_obj sinks_by_tier action_fh} {
  variable CFG

  set net_name [dbGet $net_ptr.name]
  set upper_inst_sinks [dict get $sinks_by_tier upper_inst]
  set bottom_inst_sinks [dict get $sinks_by_tier bottom_inst]
  set upper_term_sinks [dict get $sinks_by_tier upper_term]
  set bottom_term_sinks [dict get $sinks_by_tier bottom_term]

  set upper_count [llength $upper_inst_sinks]
  set bottom_count [llength $bottom_inst_sinks]
  set buffer_tier [::mixed_tier_split::choose_buffer_tier $upper_count $bottom_count]

  set moved_inst_sinks {}
  set moved_term_sinks {}
  set retained_tier ""
  if {$buffer_tier eq "upper"} {
    set moved_inst_sinks $upper_inst_sinks
    set moved_term_sinks $upper_term_sinks
    set retained_tier "bottom"
  } else {
    set moved_inst_sinks $bottom_inst_sinks
    set moved_term_sinks $bottom_term_sinks
    set retained_tier "upper"
  }

  if {[llength $moved_inst_sinks] == 0 && [llength $moved_term_sinks] == 0} {
    return [list 0 "no_sinks_on_selected_buffer_tier"]
  }
  if {[llength $moved_term_sinks] > 0} {
    return [list 0 "top_level_sink_rewire_not_supported"]
  }

  set buffer_info [::mixed_tier_split::choose_buffer_master $buffer_tier]
  if {$buffer_info eq ""} {
    return [list 0 "no_tier_buffer_master"]
  }
  lassign $buffer_info buffer_master _ _

  set existing_names [concat [dbGet top.nets.name] [dbGet top.insts.name]]
  set safe_net_name [::mixed_tier_split::sanitize_name_component $net_name]
  set inst_name [::mixed_tier_split::ensure_unique_name [format "%s_%s_%s" $CFG(inst_prefix) $buffer_tier $safe_net_name] $existing_names]
  set branch_net [::mixed_tier_split::ensure_unique_name [format "%s_%s_%s" $CFG(net_prefix) $buffer_tier $safe_net_name] $existing_names]

  puts $action_fh "ACTION net=$net_name driver=[::mixed_tier_split::object_label $driver_obj] buffer_master=$buffer_master buffer_tier=$buffer_tier retained_tier=$retained_tier new_inst=$inst_name new_net=$branch_net"

  if {$CFG(dry_run)} {
    foreach inst_term $moved_inst_sinks {
      puts $action_fh "  DRYRUN MOVE [dbGet $inst_term.name] -> $branch_net"
    }
    return [list 1 ""]
  }

  set moved_pin_names [::mixed_tier_split::inst_term_names $moved_inst_sinks]
  set moved_pin_arg [join $moved_pin_names " "]
  if {[catch {
    ecoAddRepeater \
      -term $moved_pin_arg \
      -cell $buffer_master \
      -name $inst_name \
      -newNetName $branch_net \
      -logicalChangeOnly
  } eco_err]} {
    return [list 0 [format "eco_add_repeater_failed:%s" $eco_err]]
  }

  foreach moved_pin $moved_pin_names {
    puts $action_fh "  MOVE SINK $moved_pin -> $branch_net"
  }

  return [list 1 ""]
}

proc ::mixed_tier_split::is_processed_net_tier_pure {net_ptr} {
  set sinks_by_tier [::mixed_tier_split::collect_sinks_by_tier $net_ptr]
  set upper_total [expr {[llength [dict get $sinks_by_tier upper_inst]] + [llength [dict get $sinks_by_tier upper_term]]}]
  set bottom_total [expr {[llength [dict get $sinks_by_tier bottom_inst]] + [llength [dict get $sinks_by_tier bottom_term]]}]
  return [expr {!($upper_total > 0 && $bottom_total > 0)}]
}

proc ::mixed_tier_split::run {} {
  variable CFG
  variable COUNTERS
  variable SKIP_REASONS
  variable PROCESSED_NETS

  array set COUNTERS {
    candidate_nets       0
    mixed_nets           0
    split_nets           0
    skipped_nets         0
    processed_residual   0
    io_upper             0
    io_bottom            0
  }
  array unset SKIP_REASONS
  array set SKIP_REASONS {}
  set PROCESSED_NETS {}

  foreach term [dbGet -e top.terms] {
    switch -- [tier_classify_term_ptr $term] {
      upper {
        incr COUNTERS(io_upper)
      }
      bottom {
        incr COUNTERS(io_bottom)
      }
    }
  }

  set action_fh [open $CFG(action_file) w]
  puts $action_fh "# Mixed-tier net split actions"
  puts $action_fh "# split_net_mode=enabled"
  puts $action_fh "# dry_run=$CFG(dry_run)"

  foreach net_ptr [dbGet -e top.nets] {
    set net_name [dbGet $net_ptr.name]
    lassign [::mixed_tier_split::is_candidate_net $net_ptr] is_candidate reason
    if {!$is_candidate} {
      ::mixed_tier_split::record_skip $reason
      puts $action_fh "SKIP $net_name reason=$reason"
      continue
    }

    incr COUNTERS(candidate_nets)

    lassign [::mixed_tier_split::get_net_driver $net_ptr] driver_obj driver_reason
    if {$driver_obj eq ""} {
      ::mixed_tier_split::record_skip $driver_reason
      puts $action_fh "SKIP $net_name reason=$driver_reason"
      continue
    }

    if {[llength [dbGet -e $net_ptr.terms]] > 0} {
      ::mixed_tier_split::record_skip "top_level_term_net_not_supported"
      puts $action_fh "SKIP $net_name reason=top_level_term_net_not_supported"
      continue
    }

    set driver_type [dbGet $driver_obj.objType]
    if {$driver_type eq "instTerm"} {
      set driver_inst [dbGet -e $driver_obj.inst]
      if {[dbGet $driver_inst.cell.baseClass] eq "block"} {
        ::mixed_tier_split::record_skip "driver_is_block"
        puts $action_fh "SKIP $net_name reason=driver_is_block"
        continue
      }
      if {[tier_classify_inst_ptr $driver_inst] eq "unknown"} {
        ::mixed_tier_split::record_skip "driver_unknown_tier"
        puts $action_fh "SKIP $net_name reason=driver_unknown_tier"
        continue
      }
    } else {
      if {[tier_classify_term_ptr $driver_obj] eq "unknown"} {
        ::mixed_tier_split::record_skip "driver_unknown_tier"
        puts $action_fh "SKIP $net_name reason=driver_unknown_tier"
        continue
      }
    }

    set sinks_by_tier [::mixed_tier_split::collect_sinks_by_tier $net_ptr]
    if {[llength [dict get $sinks_by_tier unknown]] > 0} {
      ::mixed_tier_split::record_skip "unknown_sink_tier"
      puts $action_fh "SKIP $net_name reason=unknown_sink_tier"
      continue
    }

    set upper_total [expr {[llength [dict get $sinks_by_tier upper_inst]] + [llength [dict get $sinks_by_tier upper_term]]}]
    set bottom_total [expr {[llength [dict get $sinks_by_tier bottom_inst]] + [llength [dict get $sinks_by_tier bottom_term]]}]

    if {$upper_total == 0 || $bottom_total == 0} {
      continue
    }

    incr COUNTERS(mixed_nets)

    lassign [::mixed_tier_split::split_net_with_buffer $net_ptr $driver_obj $sinks_by_tier $action_fh] ok split_reason
    if {!$ok} {
      ::mixed_tier_split::record_skip $split_reason
      puts $action_fh "SKIP $net_name reason=$split_reason"
      continue
    }

    incr COUNTERS(split_nets)
    lappend PROCESSED_NETS $net_name
  }

  if {!$CFG(dry_run) && $CFG(run_eco_place)} {
    ecoPlace
  }

  if {$CFG(verify_processed)} {
    foreach net_name $PROCESSED_NETS {
      set net_ptr [dbGet -e [dbGet -p top.nets.name $net_name]]
      if {$net_ptr eq ""} {
        continue
      }
      if {![::mixed_tier_split::is_processed_net_tier_pure $net_ptr]} {
        incr COUNTERS(processed_residual)
        puts $action_fh "VERIFY_FAIL $net_name reason=processed_net_still_mixed"
      }
    }
  }

  close $action_fh

  set summary_fh [open $CFG(report_file) w]
  puts $summary_fh "mode enabled"
  puts $summary_fh "candidate_nets $COUNTERS(candidate_nets)"
  puts $summary_fh "mixed_tier_nets $COUNTERS(mixed_nets)"
  puts $summary_fh "split_nets $COUNTERS(split_nets)"
  puts $summary_fh "skipped_nets $COUNTERS(skipped_nets)"
  puts $summary_fh "processed_residual $COUNTERS(processed_residual)"
  puts $summary_fh "io_upper $COUNTERS(io_upper)"
  puts $summary_fh "io_bottom $COUNTERS(io_bottom)"
  puts $summary_fh ""
  puts $summary_fh "skip_reasons"
  foreach reason [lsort [array names SKIP_REASONS]] {
    puts $summary_fh [format "  %s %d" $reason $SKIP_REASONS($reason)]
  }
  close $summary_fh

  puts "INFO: mixed-tier split summary -> $CFG(report_file)"
  puts "INFO:   candidate_nets=$COUNTERS(candidate_nets)"
  puts "INFO:   mixed_tier_nets=$COUNTERS(mixed_nets)"
  puts "INFO:   split_nets=$COUNTERS(split_nets)"
  puts "INFO:   skipped_nets=$COUNTERS(skipped_nets)"
  puts "INFO:   processed_residual=$COUNTERS(processed_residual)"
  puts "INFO:   io_upper=$COUNTERS(io_upper) io_bottom=$COUNTERS(io_bottom)"
}
