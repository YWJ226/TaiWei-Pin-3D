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
    detail_log           0
    net_prefix           SPLITNET
    inst_prefix          SPLITBUF
    util_safe            0.60
    util_alpha           12.0
    util_weight          1.0
    hbt_weight           2.5
    area_weight          400.0
    high_util_forbid     0.8
    near_tie_ratio       0.05
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
    existing_split_bufs  0
  }

  variable SKIP_REASONS
  array set SKIP_REASONS {}

  variable PROCESSED_SPLITS {}

  variable BUFFER_MASTER_CHOICES
  array set BUFFER_MASTER_CHOICES {}

  variable USED_NET_NAMES
  array set USED_NET_NAMES {}

  variable USED_INST_NAMES
  array set USED_INST_NAMES {}

  variable NET_PTR_CACHE
  array set NET_PTR_CACHE {}

  variable TIER_UTILIZATION {}
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

proc ::mixed_tier_split::init_name_cache {} {
  variable USED_NET_NAMES
  variable USED_INST_NAMES
  variable NET_PTR_CACHE

  catch {array unset USED_NET_NAMES}
  catch {array unset USED_INST_NAMES}
  catch {array unset NET_PTR_CACHE}
  array set USED_NET_NAMES {}
  array set USED_INST_NAMES {}
  array set NET_PTR_CACHE {}

  foreach net_ptr [dbGet -e top.nets] {
    set net_name [::mixed_tier_split::normalize_object_name [dbGet $net_ptr.name]]
    if {$net_name ne ""} {
      set USED_NET_NAMES($net_name) 1
      set NET_PTR_CACHE($net_name) $net_ptr
    }
  }
  foreach inst_name [dbGet top.insts.name] {
    if {$inst_name ne ""} {
      set USED_INST_NAMES($inst_name) 1
    }
  }
}

proc ::mixed_tier_split::reserve_name {kind name} {
  variable USED_NET_NAMES
  variable USED_INST_NAMES

  switch -- $kind {
    net {
      set USED_NET_NAMES($name) 1
    }
    inst {
      set USED_INST_NAMES($name) 1
    }
  }
}

proc ::mixed_tier_split::name_exists {kind name} {
  variable USED_NET_NAMES
  variable USED_INST_NAMES

  switch -- $kind {
    net {
      return [info exists USED_NET_NAMES($name)]
    }
    inst {
      return [info exists USED_INST_NAMES($name)]
    }
  }
  return 0
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

proc ::mixed_tier_split::numeric_or_zero {value} {
  if {[catch {expr {double($value)}} result]} {
    return 0.0
  }
  return $result
}

proc ::mixed_tier_split::core_area_um2 {} {
  if {![catch {set area [dbGet top.fPlan.coreBox_area]}] && $area ne ""} {
    set area [lindex $area 0]
    if {[::mixed_tier_split::numeric_or_zero $area] > 0.0} {
      return [::mixed_tier_split::numeric_or_zero $area]
    }
  }

  if {![catch {set core_box [dbGet top.fPlan.coreBox]}] && $core_box ne ""} {
    set box [::mixed_tier_split::box_flat4 $core_box]
    if {[llength $box] == 4} {
      lassign $box lx ly ux uy
      set width [expr {abs(double($ux) - double($lx))}]
      set height [expr {abs(double($uy) - double($ly))}]
      return [expr {$width * $height}]
    }
  }
  return 0.0
}

proc ::mixed_tier_split::inst_area_um2 {inst_ptr} {
  set area 0.0
  if {![catch {set area [dbGet $inst_ptr.area]}] && $area ne ""} {
    set area [::mixed_tier_split::numeric_or_zero [lindex $area 0]]
  }
  if {$area <= 0.0 && ![catch {set area [dbGet $inst_ptr.cell.area]}] && $area ne ""} {
    set area [::mixed_tier_split::numeric_or_zero [lindex $area 0]]
  }
  return $area
}

proc ::mixed_tier_split::compute_tier_global_utilization {} {
  variable TIER_UTILIZATION
  if {$TIER_UTILIZATION ne ""} {
    return $TIER_UTILIZATION
  }

  set core_area [::mixed_tier_split::core_area_um2]
  set upper_area 0.0
  set bottom_area 0.0
  set upper_count 0
  set bottom_count 0
  foreach inst_ptr [dbGet -e top.insts] {
    set tier [tier_classify_inst_ptr $inst_ptr]
    if {$tier ni {upper bottom}} {
      continue
    }
    set area [::mixed_tier_split::inst_area_um2 $inst_ptr]
    if {$tier eq "upper"} {
      set upper_area [expr {$upper_area + $area}]
      incr upper_count
    } else {
      set bottom_area [expr {$bottom_area + $area}]
      incr bottom_count
    }
  }

  set util_upper 0.0
  set util_bottom 0.0
  set total_cell_area [expr {$upper_area + $bottom_area}]
  if {$core_area > 0.0} {
    set util_upper [expr {$upper_area / $core_area}]
    set util_bottom [expr {$bottom_area / $core_area}]
  }

  set TIER_UTILIZATION [dict create \
    upper $util_upper \
    bottom $util_bottom \
    upper_area $upper_area \
    bottom_area $bottom_area \
    total_cell_area $total_cell_area \
    upper_count $upper_count \
    bottom_count $bottom_count \
    core_area $core_area \
    method "tier_instance_area_over_core_area"]
  return $TIER_UTILIZATION
}

proc ::mixed_tier_split::util_penalty {util} {
  variable CFG
  set util [::mixed_tier_split::numeric_or_zero $util]
  if {$util <= $CFG(util_safe)} {
    return 0.0
  }
  return [expr {exp(double($CFG(util_alpha)) * ($util - double($CFG(util_safe)))) - 1.0}]
}

proc ::mixed_tier_split::estimated_extra_hbt {candidate_tier driver_tier retained_opposite_tier_sink_count} {
  if {$candidate_tier ne $driver_tier} {
    return 1
  }
  return $retained_opposite_tier_sink_count
}

proc ::mixed_tier_split::hbt_penalty {estimated_extra_hbt} {
  return [expr {log(1.0 + double($estimated_extra_hbt)) / log(2.0)}]
}

proc ::mixed_tier_split::buffer_area_penalty {buffer_area core_area} {
  set buffer_area [::mixed_tier_split::numeric_or_zero $buffer_area]
  set core_area [::mixed_tier_split::numeric_or_zero $core_area]
  if {$buffer_area <= 0.0 || $core_area <= 0.0} {
    return 0.0
  }
  return [expr {$buffer_area / $core_area}]
}

proc ::mixed_tier_split::candidate_feasibility {candidate_tier upper_inst_count bottom_inst_count upper_term_count bottom_term_count} {
  if {$candidate_tier eq "upper"} {
    if {$upper_inst_count <= 0 && $upper_term_count <= 0} {
      return [list 0 "no_supported_upper_sinks"]
    }
    if {$upper_term_count > 0} {
      return [list 0 "top_level_upper_sink_rewire_not_supported"]
    }
  } else {
    if {$bottom_inst_count <= 0 && $bottom_term_count <= 0} {
      return [list 0 "no_supported_bottom_sinks"]
    }
    if {$bottom_term_count > 0} {
      return [list 0 "top_level_bottom_sink_rewire_not_supported"]
    }
  }
  return [list 1 ""]
}

proc ::mixed_tier_split::evaluate_buffer_tier_score {candidate_tier driver_tier upper_inst_count bottom_inst_count upper_term_count bottom_term_count} {
  variable CFG
  set tier_util [::mixed_tier_split::compute_tier_global_utilization]
  set util [dict get $tier_util $candidate_tier]
  set p_util [::mixed_tier_split::util_penalty $util]
  set core_area [dict get $tier_util core_area]

  if {$candidate_tier eq "upper"} {
    set retained_opposite_count [expr {$bottom_inst_count + $bottom_term_count}]
    set moved_sink_count [expr {$upper_inst_count + $upper_term_count}]
  } else {
    set retained_opposite_count [expr {$upper_inst_count + $upper_term_count}]
    set moved_sink_count [expr {$bottom_inst_count + $bottom_term_count}]
  }
  set estimated_extra_hbt [::mixed_tier_split::estimated_extra_hbt $candidate_tier $driver_tier $retained_opposite_count]
  set p_hbt [::mixed_tier_split::hbt_penalty $estimated_extra_hbt]
  lassign [::mixed_tier_split::candidate_feasibility $candidate_tier $upper_inst_count $bottom_inst_count $upper_term_count $bottom_term_count] feasible infeasible_reason
  set buffer_master ""
  set buffer_area 0.0
  if {$feasible} {
    set buffer_info [::mixed_tier_split::choose_buffer_master $candidate_tier $moved_sink_count]
    if {$buffer_info eq ""} {
      set feasible 0
      set infeasible_reason "no_tier_buffer_master"
    } else {
      lassign $buffer_info buffer_master _ _ buffer_area _
    }
  }
  set p_area [::mixed_tier_split::buffer_area_penalty $buffer_area $core_area]
  set score [expr {double($CFG(util_weight)) * $p_util + double($CFG(hbt_weight)) * $p_hbt + double($CFG(area_weight)) * $p_area}]
  set forbidden [expr {$util >= double($CFG(high_util_forbid))}]

  return [dict create \
    tier $candidate_tier \
    score $score \
    util $util \
    p_util $p_util \
    estimated_extra_hbt $estimated_extra_hbt \
    p_hbt $p_hbt \
    buffer_master $buffer_master \
    buffer_area $buffer_area \
    core_area $core_area \
    p_area $p_area \
    feasible $feasible \
    infeasible_reason $infeasible_reason \
    high_util_forbid $forbidden]
}

proc ::mixed_tier_split::opposite_tier {tier} {
  switch -- $tier {
    upper { return bottom }
    bottom { return upper }
    default { return unknown }
  }
}

proc ::mixed_tier_split::prefer_score_record {upper_eval bottom_eval driver_tier} {
  variable CFG
  set upper_feasible [dict get $upper_eval feasible]
  set bottom_feasible [dict get $bottom_eval feasible]
  if {!$upper_feasible && !$bottom_feasible} {
    return [list "" "no_supported_instance_sinks"]
  }
  if {$upper_feasible && !$bottom_feasible} {
    return [list upper "only_upper_feasible"]
  }
  if {$bottom_feasible && !$upper_feasible} {
    return [list bottom "only_bottom_feasible"]
  }

  set upper_forbidden [dict get $upper_eval high_util_forbid]
  set bottom_forbidden [dict get $bottom_eval high_util_forbid]
  if {$upper_forbidden && !$bottom_forbidden} {
    return [list bottom "upper_high_util_guard"]
  }
  if {$bottom_forbidden && !$upper_forbidden} {
    return [list upper "bottom_high_util_guard"]
  }

  set score_upper [dict get $upper_eval score]
  set score_bottom [dict get $bottom_eval score]
  set min_score [expr {($score_upper < $score_bottom) ? $score_upper : $score_bottom}]
  set diff [expr {abs($score_upper - $score_bottom)}]
  if {$min_score <= 1.0e-12} {
    set near_tie [expr {$diff < double($CFG(near_tie_ratio))}]
  } else {
    set near_tie [expr {($diff / $min_score) < double($CFG(near_tie_ratio))}]
  }

  if {!$near_tie} {
    if {$score_upper <= $score_bottom} {
      return [list upper "lower_score"]
    }
    return [list bottom "lower_score"]
  }

  set p_util_upper [dict get $upper_eval p_util]
  set p_util_bottom [dict get $bottom_eval p_util]
  if {$p_util_upper < $p_util_bottom} {
    return [list upper "near_tie_lower_util_penalty"]
  }
  if {$p_util_bottom < $p_util_upper} {
    return [list bottom "near_tie_lower_util_penalty"]
  }

  set hbt_upper [dict get $upper_eval estimated_extra_hbt]
  set hbt_bottom [dict get $bottom_eval estimated_extra_hbt]
  if {$hbt_upper < $hbt_bottom} {
    return [list upper "near_tie_lower_estimated_extra_hbt"]
  }
  if {$hbt_bottom < $hbt_upper} {
    return [list bottom "near_tie_lower_estimated_extra_hbt"]
  }

  set p_area_upper [dict get $upper_eval p_area]
  set p_area_bottom [dict get $bottom_eval p_area]
  if {$p_area_upper < $p_area_bottom} {
    return [list upper "near_tie_lower_area_penalty"]
  }
  if {$p_area_bottom < $p_area_upper} {
    return [list bottom "near_tie_lower_area_penalty"]
  }

  set opposite [::mixed_tier_split::opposite_tier $driver_tier]
  if {$opposite in {upper bottom}} {
    return [list $opposite "near_tie_opposite_driver_tier"]
  }
  return [list upper "near_tie_lexical_upper"]
}

proc ::mixed_tier_split::choose_buffer_tier {driver_tier upper_inst_count bottom_inst_count upper_term_count bottom_term_count} {
  if {$driver_tier ni {upper bottom}} {
    return [list "" "driver_tier_unknown" [dict create]]
  }
  set upper_eval [::mixed_tier_split::evaluate_buffer_tier_score upper $driver_tier $upper_inst_count $bottom_inst_count $upper_term_count $bottom_term_count]
  set bottom_eval [::mixed_tier_split::evaluate_buffer_tier_score bottom $driver_tier $upper_inst_count $bottom_inst_count $upper_term_count $bottom_term_count]
  lassign [::mixed_tier_split::prefer_score_record $upper_eval $bottom_eval $driver_tier] tier reason
  return [list $tier $reason [dict create upper $upper_eval bottom $bottom_eval selection_reason $reason]]
}

proc ::mixed_tier_split::format_decision_fields {decision} {
  if {$decision eq "" || ![dict exists $decision upper] || ![dict exists $decision bottom]} {
    return ""
  }
  set upper [dict get $decision upper]
  set bottom [dict get $decision bottom]
  return [format "score_upper=%.6g score_bottom=%.6g util_upper=%.6g util_bottom=%.6g p_util_upper=%.6g p_util_bottom=%.6g estimated_extra_hbt_upper=%d estimated_extra_hbt_bottom=%d p_hbt_upper=%.6g p_hbt_bottom=%.6g buffer_master_upper=%s buffer_master_bottom=%s buffer_area_upper=%.6g buffer_area_bottom=%.6g core_area=%.6g p_area_upper=%.6g p_area_bottom=%.6g high_util_forbid_upper=%d high_util_forbid_bottom=%d" \
    [dict get $upper score] \
    [dict get $bottom score] \
    [dict get $upper util] \
    [dict get $bottom util] \
    [dict get $upper p_util] \
    [dict get $bottom p_util] \
    [dict get $upper estimated_extra_hbt] \
    [dict get $bottom estimated_extra_hbt] \
    [dict get $upper p_hbt] \
    [dict get $bottom p_hbt] \
    [dict get $upper buffer_master] \
    [dict get $bottom buffer_master] \
    [dict get $upper buffer_area] \
    [dict get $bottom buffer_area] \
    [dict get $upper core_area] \
    [dict get $upper p_area] \
    [dict get $bottom p_area] \
    [dict get $upper high_util_forbid] \
    [dict get $bottom high_util_forbid]]
}

proc ::mixed_tier_split::buffer_drive_score {master_name} {
  set score 999999
  if {[regexp -nocase -- {[_x]([0-9]+)(?:_|$)} $master_name -> drive]} {
    set score $drive
  }
  return $score
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

proc ::mixed_tier_split::master_area_um2 {master_name} {
  set cell_ptr [dbGet -p head.libCells.name $master_name]
  if {$cell_ptr eq "0x0"} {
    return 0.0
  }
  set size_x [::mixed_tier_split::numeric_or_zero [dbGet $cell_ptr.size_x]]
  set size_y [::mixed_tier_split::numeric_or_zero [dbGet $cell_ptr.size_y]]
  return [expr {$size_x * $size_y}]
}

proc ::mixed_tier_split::choose_buffer_master {tier {moved_sink_count 1}} {
  variable BUFFER_MASTER_CHOICES
  if {![info exists BUFFER_MASTER_CHOICES($tier)]} {
    set candidates {}
    foreach candidate [dbGet head.libCells.name] {
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
        lappend candidates [list [::mixed_tier_split::buffer_drive_score $candidate] $candidate $in_term $out_term [::mixed_tier_split::master_area_um2 $candidate]]
      }
    }
    set BUFFER_MASTER_CHOICES($tier) [lsort -integer -index 0 [lsort -dictionary -index 1 $candidates]]
  }

  set sorted $BUFFER_MASTER_CHOICES($tier)
  if {[llength $sorted] == 0} {
    return ""
  }
  set smallest [lindex $sorted 0]
  return [concat [lrange $smallest 1 end] [list [lindex $smallest 0]]]
}

proc ::mixed_tier_split::object_label {obj_ptr} {
  set obj_type [dbGet $obj_ptr.objType]
  if {$obj_type eq "instTerm"} {
    return [dbGet $obj_ptr.name]
  }
  return [dbGet $obj_ptr.name]
}

proc ::mixed_tier_split::ensure_unique_name {kind base} {
  set name $base
  set idx 0
  while {[::mixed_tier_split::name_exists $kind $name]} {
    incr idx
    set name "${base}_${idx}"
  }
  ::mixed_tier_split::reserve_name $kind $name
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

proc ::mixed_tier_split::net_ptr_from_exact_name {net_name} {
  variable NET_PTR_CACHE

  set normalized_name [::mixed_tier_split::normalize_object_name $net_name]
  if {[info exists NET_PTR_CACHE($normalized_name)]} {
    set cached_ptr $NET_PTR_CACHE($normalized_name)
    if {$cached_ptr ne "" && $cached_ptr ne "0x0"} {
      if {![catch {set cached_name [dbGet $cached_ptr.name]}] && $cached_name ne ""} {
        if {[::mixed_tier_split::normalize_object_name $cached_name] eq $normalized_name} {
          return $cached_ptr
        }
      }
    }
    unset NET_PTR_CACHE($normalized_name)
  }

  foreach net_ptr [dbGet -e top.nets] {
    set current_name [::mixed_tier_split::normalize_object_name [dbGet $net_ptr.name]]
    if {$current_name eq $normalized_name} {
      set NET_PTR_CACHE($normalized_name) $net_ptr
      return $net_ptr
    }
  }
  return ""
}

proc ::mixed_tier_split::resolve_live_net_ptr {net_ptr net_name} {
  set normalized_name [::mixed_tier_split::normalize_object_name $net_name]
  if {$net_ptr ne "" && $net_ptr ne "0x0"} {
    if {![catch {set current_name [dbGet $net_ptr.name]}] && $current_name ne ""} {
      if {[::mixed_tier_split::normalize_object_name $current_name] eq $normalized_name} {
        return $net_ptr
      }
    }
  }
  return [::mixed_tier_split::net_ptr_from_exact_name $normalized_name]
}

proc ::mixed_tier_split::inst_term_names {inst_terms} {
  set names {}
  foreach inst_term $inst_terms {
    lappend names [::mixed_tier_split::normalize_object_name [dbGet $inst_term.name]]
  }
  return $names
}

proc ::mixed_tier_split::is_processed_net_fanout_pure {net_ptr} {
  set sinks_by_tier [::mixed_tier_split::collect_sinks_by_tier $net_ptr]
  set upper_total [expr {[llength [dict get $sinks_by_tier upper_inst]] + [llength [dict get $sinks_by_tier upper_term]]}]
  set bottom_total [expr {[llength [dict get $sinks_by_tier bottom_inst]] + [llength [dict get $sinks_by_tier bottom_term]]}]
  return [expr {!($upper_total > 0 && $bottom_total > 0)}]
}

proc ::mixed_tier_split::verify_split_result {original_net_ptr original_net_name branch_net_name} {
  set original_net_ptr [::mixed_tier_split::resolve_live_net_ptr $original_net_ptr $original_net_name]
  if {$original_net_ptr eq "" || $original_net_ptr eq "0x0"} {
    return [list 0 "original_net_missing"]
  }
  set branch_net_ptr [::mixed_tier_split::net_ptr_from_exact_name $branch_net_name]
  if {$branch_net_ptr eq "" || $branch_net_ptr eq "0x0"} {
    return [list 0 "branch_net_missing"]
  }
  if {![::mixed_tier_split::is_processed_net_fanout_pure $original_net_ptr]} {
    return [list 0 "original_net_still_mixed_fanout"]
  }
  if {![::mixed_tier_split::is_processed_net_fanout_pure $branch_net_ptr]} {
    return [list 0 "branch_net_still_mixed_fanout"]
  }
  return [list 1 ""]
}

proc ::mixed_tier_split::rollback_split {inst_name branch_net action_fh} {
  set rollback_ok 1
  if {[catch {deleteInst $inst_name} rollback_err]} {
    set rollback_ok 0
    puts $action_fh "  ROLLBACK_FAIL inst=$inst_name error=$rollback_err"
  } else {
    puts $action_fh "  ROLLBACK_DELETE_INST $inst_name"
  }
  if {$rollback_ok && [catch {deleteNet $branch_net} rollback_err]} {
    puts $action_fh "  ROLLBACK_WARN net=$branch_net error=$rollback_err"
  } elseif {$rollback_ok} {
    puts $action_fh "  ROLLBACK_DELETE_NET $branch_net"
  }
  return $rollback_ok
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
  set upper_term_count [llength $upper_term_sinks]
  set bottom_term_count [llength $bottom_term_sinks]
  set driver_tier [tier_classify_object_ptr $driver_obj]
  lassign [::mixed_tier_split::choose_buffer_tier $driver_tier $upper_count $bottom_count $upper_term_count $bottom_term_count] buffer_tier tier_reason decision
  if {$buffer_tier eq ""} {
    return [list 0 $tier_reason]
  }

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

  set moved_sink_count [expr {[llength $moved_inst_sinks] + [llength $moved_term_sinks]}]
  set buffer_info [::mixed_tier_split::choose_buffer_master $buffer_tier]
  if {$buffer_info eq ""} {
    return [list 0 "no_tier_buffer_master"]
  }
  lassign $buffer_info buffer_master _ _ buffer_area chosen_drive

  set safe_net_name [::mixed_tier_split::sanitize_name_component $net_name]
  set inst_name [::mixed_tier_split::ensure_unique_name inst [format "%s_%s_%s" $CFG(inst_prefix) $buffer_tier $safe_net_name]]
  set branch_net [::mixed_tier_split::ensure_unique_name net [format "%s_%s_%s" $CFG(net_prefix) $buffer_tier $safe_net_name]]

  set decision_fields [::mixed_tier_split::format_decision_fields $decision]
  puts $action_fh "ACTION net=$net_name driver=[::mixed_tier_split::object_label $driver_obj] driver_tier=$driver_tier buffer_master=$buffer_master buffer_area=$buffer_area buffer_tier=$buffer_tier retained_tier=$retained_tier chosen_tier=$buffer_tier selection_reason=$tier_reason $decision_fields moved_sink_count=$moved_sink_count chosen_drive=$chosen_drive new_inst=$inst_name new_net=$branch_net"

  if {$CFG(dry_run)} {
    if {$CFG(detail_log)} {
      foreach inst_term $moved_inst_sinks {
        puts $action_fh "  DRYRUN MOVE [dbGet $inst_term.name] -> $branch_net"
      }
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

  if {$CFG(detail_log)} {
    foreach moved_pin $moved_pin_names {
      puts $action_fh "  MOVE SINK $moved_pin -> $branch_net"
    }
  }

  if {$CFG(verify_processed)} {
    lassign [::mixed_tier_split::verify_split_result $net_ptr $net_name $branch_net] verify_ok verify_reason
    if {!$verify_ok} {
      puts $action_fh "  VERIFY_FAIL net=$net_name branch=$branch_net reason=$verify_reason"
      ::mixed_tier_split::rollback_split $inst_name $branch_net $action_fh
      return [list 0 $verify_reason]
    }
    if {$CFG(detail_log)} {
      puts $action_fh "  VERIFY_OK net=$net_name branch=$branch_net"
    }
  }

  return [list 1 $branch_net]
}

proc ::mixed_tier_split::run {} {
  variable CFG
  variable COUNTERS
  variable SKIP_REASONS
  variable PROCESSED_SPLITS
  variable BUFFER_MASTER_CHOICES
  variable TIER_UTILIZATION

  set t_run_start [clock milliseconds]
  set TIER_UTILIZATION {}

  array set COUNTERS {
    candidate_nets       0
    mixed_nets           0
    split_nets           0
    skipped_nets         0
    processed_residual   0
    io_upper             0
    io_bottom            0
    existing_split_bufs  0
  }
  array unset SKIP_REASONS
  array set SKIP_REASONS {}
  set PROCESSED_SPLITS {}
  catch {array unset BUFFER_MASTER_CHOICES}
  array set BUFFER_MASTER_CHOICES {}
  set t_name_cache_start [clock milliseconds]
  ::mixed_tier_split::init_name_cache
  set t_name_cache_ms [expr {[clock milliseconds] - $t_name_cache_start}]
  set tier_util [::mixed_tier_split::compute_tier_global_utilization]

  if {[info exists ::env(PIN3D_SPLIT_DETAIL_LOG)] && $::env(PIN3D_SPLIT_DETAIL_LOG) ne ""} {
    set CFG(detail_log) [expr {$::env(PIN3D_SPLIT_DETAIL_LOG) ni {0 false FALSE off OFF no NO}}]
  }

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
  puts $action_fh "# detail_log=$CFG(detail_log)"
  puts $action_fh "# name_cache_ms=$t_name_cache_ms"
  puts $action_fh "# tier_utilization method=[dict get $tier_util method] core_area=[dict get $tier_util core_area] util_upper=[dict get $tier_util upper] util_bottom=[dict get $tier_util bottom] area_upper=[dict get $tier_util upper_area] area_bottom=[dict get $tier_util bottom_area] total_cell_area=[dict get $tier_util total_cell_area]"
  puts $action_fh "# cost_policy util_safe=$CFG(util_safe) util_alpha=$CFG(util_alpha) util_weight=$CFG(util_weight) hbt_weight=$CFG(hbt_weight) area_weight=$CFG(area_weight) high_util_forbid=$CFG(high_util_forbid) near_tie_ratio=$CFG(near_tie_ratio)"

  foreach inst_ptr [dbGet -e top.insts] {
    set inst_name [dbGet $inst_ptr.name]
    if {[string match "${CFG(inst_prefix)}*" $inst_name]} {
      incr COUNTERS(existing_split_bufs)
    }
  }
  puts $action_fh "# existing_split_bufs=$COUNTERS(existing_split_bufs)"
  if {$COUNTERS(existing_split_bufs) > 0} {
    puts $action_fh "# warning=input_already_contains_split_buffers"
  }

  set eco_batch_mode_enabled 0
  if {!$CFG(dry_run) && [llength [info commands setEcoMode]]} {
    if {![catch {setEcoMode -batchMode true}]} {
      set eco_batch_mode_enabled 1
      puts $action_fh "# eco_batch_mode=on"
    }
  }

  set t_scan_start [clock milliseconds]
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

    lassign [::mixed_tier_split::split_net_with_buffer $net_ptr $driver_obj $sinks_by_tier $action_fh] ok split_result
    if {!$ok} {
      ::mixed_tier_split::record_skip $split_result
      puts $action_fh "SKIP $net_name reason=$split_result"
      continue
    }

    incr COUNTERS(split_nets)
    lappend PROCESSED_SPLITS [list $net_name $split_result]
  }
  set t_scan_ms [expr {[clock milliseconds] - $t_scan_start}]

  set t_batch_close_start [clock milliseconds]
  if {$eco_batch_mode_enabled} {
    catch {setEcoMode -batchMode false}
  }
  set t_batch_close_ms [expr {[clock milliseconds] - $t_batch_close_start}]

  set t_eco_place_start [clock milliseconds]
  if {!$CFG(dry_run) && $CFG(run_eco_place)} {
    ecoPlace
  }
  set t_eco_place_ms [expr {[clock milliseconds] - $t_eco_place_start}]

  set t_reverify_start [clock milliseconds]
  if {$CFG(verify_processed) && $CFG(run_eco_place)} {
    foreach split_record $PROCESSED_SPLITS {
      lassign $split_record net_name branch_net_name
      set net_ptr [::mixed_tier_split::net_ptr_from_exact_name $net_name]
      if {$net_ptr eq "" || $net_ptr eq "0x0"} {
        continue
      }
      lassign [::mixed_tier_split::verify_split_result $net_ptr $net_name $branch_net_name] verify_ok verify_reason
      if {!$verify_ok} {
        incr COUNTERS(processed_residual)
        puts $action_fh "VERIFY_FAIL $net_name branch=$branch_net_name reason=$verify_reason"
      }
    }
  }
  set t_reverify_ms [expr {[clock milliseconds] - $t_reverify_start}]
  set t_total_ms [expr {[clock milliseconds] - $t_run_start}]

  close $action_fh

  set summary_fh [open $CFG(report_file) w]
  puts $summary_fh "mode enabled"
  puts $summary_fh "candidate_nets $COUNTERS(candidate_nets)"
  puts $summary_fh "mixed_tier_nets $COUNTERS(mixed_nets)"
  puts $summary_fh "mixed_fanout_nets $COUNTERS(mixed_nets)"
  puts $summary_fh "split_nets $COUNTERS(split_nets)"
  puts $summary_fh "skipped_nets $COUNTERS(skipped_nets)"
  puts $summary_fh "processed_residual $COUNTERS(processed_residual)"
  puts $summary_fh "io_upper $COUNTERS(io_upper)"
  puts $summary_fh "io_bottom $COUNTERS(io_bottom)"
  puts $summary_fh "existing_split_bufs $COUNTERS(existing_split_bufs)"
  puts $summary_fh "util_upper [dict get $tier_util upper]"
  puts $summary_fh "util_bottom [dict get $tier_util bottom]"
  puts $summary_fh "util_method [dict get $tier_util method]"
  puts $summary_fh "total_cell_area [dict get $tier_util total_cell_area]"
  puts $summary_fh "util_safe $CFG(util_safe)"
  puts $summary_fh "util_alpha $CFG(util_alpha)"
  puts $summary_fh "util_weight $CFG(util_weight)"
  puts $summary_fh "hbt_weight $CFG(hbt_weight)"
  puts $summary_fh "area_weight $CFG(area_weight)"
  puts $summary_fh "high_util_forbid $CFG(high_util_forbid)"
  puts $summary_fh "near_tie_ratio $CFG(near_tie_ratio)"
  puts $summary_fh "name_cache_ms $t_name_cache_ms"
  puts $summary_fh "scan_ms $t_scan_ms"
  puts $summary_fh "batch_close_ms $t_batch_close_ms"
  puts $summary_fh "eco_place_ms $t_eco_place_ms"
  puts $summary_fh "reverify_ms $t_reverify_ms"
  puts $summary_fh "total_ms $t_total_ms"
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
  puts "INFO:   existing_split_bufs=$COUNTERS(existing_split_bufs)"
  puts "INFO:   split_timing name_cache_ms=$t_name_cache_ms scan_ms=$t_scan_ms batch_close_ms=$t_batch_close_ms eco_place_ms=$t_eco_place_ms reverify_ms=$t_reverify_ms total_ms=$t_total_ms"
}
