# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# tier_cell_policy.tcl — Upper/Bottom “do-not-use + filler/tap” policy
# Depends on environment variables (all optional, will try to auto-fallback if empty):
#   DONT_USE_CELLS_UPPER
#   DONT_USE_CELLS_BOTTOM
#   FILL_CELLS_UPPER
#   FILL_CELLS_BOTTOM
#   TAPCELL_UPPER   (optional; explicitly specify for addWellTap/by layer)
#   TAPCELL_BOTTOM
# Usage:
#   source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
#   apply_tier_policy upper   (or bottom)
# ==========================================
source $::env(CADENCE_SCRIPTS_DIR)/place_macro_util.tcl
source $::env(CADENCE_SCRIPTS_DIR)/tier_classification.tcl

proc _as_list {envname} {
  if {[info exists ::env($envname)] && $::env($envname) ne ""} {
    return $::env($envname)
  }
  return {}
}

# Compatible set_dont_use (recognized by Innovus/Encounter/Genus)
proc _set_dont_use {cells {flag true}} {
  foreach c $cells {
    catch { set_dont_use $c $flag }
    # Some versions don't accept the boolean second argument, so fallback to single-argument syntax (sets to true)
    if {$flag} { catch { set_dont_use $c } }
    puts "set_dont_use $c"
  }
}

# Expand wildcard names into lib cell objects/names, as robustly as possible
# Expand wildcard names into lib cell objects/names, robustly for Common UI
proc _expand_libcells {patterns} {
  set out {}
  foreach p $patterns {
    if {![catch {set hits [get_lib_cells $p]}]} {
      if {[llength $hits] > 0} {
        foreach h $hits {
          if {[catch {set name [get_object_name $h]} err]} {
             if {[catch {set name [get_property $h name]} err2]} {
                set name $h
             }
          }
          lappend out $name
        }
        continue
      }
    }
    lappend out $p
  }
  return [lsort -unique $out]
}

# Optional: Restrict optimization to an "allowlist" (stronger than just don't_use)
# After passing an allow list, it will apply dont_use to "all_cells - allow_list"; disabled by default.
proc _enforce_allowlist {allow_patterns} {
  if {![llength $allow_patterns]} { return }
  set allow  [_expand_libcells $allow_patterns]
  # Get the full set (all standard cells)
  set all ""
  catch { set all [get_lib_cells *] }
  if {$all eq ""} { return }
  # Calculate the difference
  array set mark {}
  foreach a $allow { set mark($a) 1 }
  set ban {}
  foreach a $all { if {![info exists mark($a)]} { lappend ban $a } }
  _set_dont_use $ban true
}

proc box_flat4 {box} {
  if {[llength $box] == 1} { set box [lindex $box 0] }
  if {[llength $box] == 2 && [llength [lindex $box 0]] == 2} {
    set ll [lindex $box 0]; set ur [lindex $box 1]
    return [list [lindex $ll 0] [lindex $ll 1] [lindex $ur 0] [lindex $ur 1]]
  }
  return $box
}

proc rebuild_rows_for_site {site_name tier {core_margin 0}} {
  # 1. Basic validation
  if {$site_name eq ""} {
    puts "ERROR(INV): rebuild_rows_for_site: empty site_name."
    return
  }

  # 2. Retrieve DieBox
  set die_bbox [get_db current_design .bbox]
  
  # --- ROBUSTNESS FIX ---
  # If die_bbox is nested like {{0.0 0.0 11.4 11.2}}, llength will be 1.
  # If die_bbox is flat like {0.0 0.0 11.4 11.2}, llength will be 4.
  # We peel off the outer layer if it is nested.
  set die_bbox [lindex $die_bbox 0]
  set core_margin $::env(CORE_MARGIN)
  # Now die_bbox is guaranteed to be flat: {0.0 0.0 11.4 11.2}
  lassign $die_bbox die_x1 die_y1 die_x2 die_y2

  # 3. Calculate new area with margin applied
  set new_x1 [expr $die_x1 + $core_margin]
  set new_y1 [expr $die_y1 + $core_margin]
  set new_x2 [expr $die_x2 - $core_margin]
  set new_y2 [expr $die_y2 - $core_margin]

  # Sanity check
  if {$new_x1 >= $new_x2 || $new_y1 >= $new_y2} {
    puts "ERROR(INV): CORE_MARGIN ($core_margin) is too large for the current DieBox {$die_bbox}."
    return
  }

  puts "INFO(INV): Rebuilding rows for site '$site_name'"
  puts "INFO(INV): Row Area: {$new_x1 $new_y1 $new_x2 $new_y2}"

  # 4. Delete and Re-create
  deleteRow -all
  createRow -site $site_name -area [list $new_x1 $new_y1 $new_x2 $new_y2]
  deleteHaloFromBlock -allBlock
  lassign [pmu::_get_halos] halo_x halo_y
  foreach cell [pmu::get_tier_macro_cells $tier] {
    addHaloToBlock -cell $cell $halo_x $halo_y $halo_x $halo_y 
  }
}

# Set placement status for tier-specific COVER cells only.
# Rule:
#   - master name matches "*_upper" or "*_bottom"
#   - master has a valid site
#   - master subclass contains COVER
proc set_tier_placement_status {tier status} {
  set tier [string tolower $tier]
  set status [string tolower $status]
  if {$status eq "unfix"} {
    set status "placed"
  }

  set pattern "*_${tier}"
  set target_insts {}
  
  foreach inst [dbGet -p2 top.insts.cell.name $pattern] {
    if {[dbGet $inst.cell.site.name] ne "" && [regexp {cover} [dbGet $inst.cell.subClass]]} {
      lappend target_insts $inst
    }
  }
  if {[llength $target_insts]} {
    dbSet $target_insts.pStatus $status
  }
  puts "INFO: Set [llength $target_insts] ${tier}-tier COVER instances to '$status'."
}

# ------------------------------------------------------------
# Helper: lock instances by master/ref suffix, optionally lock their nets
#   suffix: "*_upper" or "*_bottom"
# ------------------------------------------------------------
proc set_dont_touch_by_ref_suffix {suffix args} {
  array set opt {
    -quiet      0
  }
  if {([llength $args] % 2) != 0} {
    error "set_dont_touch_by_ref_suffix: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} { error "set_dont_touch_by_ref_suffix: unknown option $k" }
    set opt($k) $v
  }

  # 1) Find instances whose master/ref name matches suffix (master name is top.insts.cell.name)
  set inst_db {}
  catch { set inst_db [dbGet -p2 top.insts.cell.name $suffix] }
  if {$inst_db eq "" || [llength $inst_db] == 0} {
    if {!$opt(-quiet)} { puts "INFO: dont_touch: no instances match ref suffix '$suffix'." }
    return
  }

  # Convert to instance names -> get_cells collection
  set inst_names [dbGet $inst_db.name]
  if {$inst_names eq "" || [llength $inst_names] == 0} {
    if {!$opt(-quiet)} { puts "INFO: dont_touch: matched '$suffix' but cannot resolve instance names." }
    return
  }

  set cells [get_cells $inst_names]

  # 2) Dont touch cells (handle version differences)
  if {[catch {set_dont_touch $cells true} _e]} {
    catch {set_dont_touch $cells}
  }
  if {!$opt(-quiet)} { puts "INFO: dont_touch: locked [llength $inst_names] cells (ref suffix '$suffix')." }
}

# ------------------------------------------------------------
# Helper:
# Return three flags for a net:
#   has_upper   : connected to at least one upper-tier object
#   has_bottom  : connected to at least one bottom-tier object
#   has_unknown : connected to at least one object with unknown tier
#
# IMPORTANT:
#   Use "dbGet -e" to avoid counting "0x0" as a real object.
# ------------------------------------------------------------
proc _net_tier_presence {net_ptr} {
  lassign [tier_net_presence_counts $net_ptr] upper_count bottom_count unknown_count
  return [list [expr {$upper_count > 0}] [expr {$bottom_count > 0}] [expr {$unknown_count > 0}]]
}

# ------------------------------------------------------------
# Net-class strategy:
#   upper_only : upper-tier objects only
#   bottom_only: bottom-tier objects only
#   mixed      : both upper-tier and bottom-tier objects, still optimizable
#   unknown    : any net with unknown-tier connectivity, kept locked
# ------------------------------------------------------------
proc _net_optimization_class {net_ptr} {
  lassign [_net_tier_presence $net_ptr] has_upper has_bottom has_unknown

  if {$has_unknown} {
    return "unknown"
  }
  if {$has_upper && $has_bottom} {
    return "mixed"
  }
  if {$has_upper} {
    return "upper_only"
  }
  if {$has_bottom} {
    return "bottom_only"
  }
  return "ignore"
}

proc _net_class_is_unlocked {allow_net klass} {
  switch -- $allow_net {
    all {
      return [expr {$klass ne "unknown"}]
    }
    upper_only {
      return [expr {$klass eq "upper_only" || $klass eq "mixed"}]
    }
    bottom_only {
      return [expr {$klass eq "bottom_only" || $klass eq "mixed"}]
    }
    default {
      error "Unexpected allow_net class '$allow_net'"
    }
  }
}

proc _lock_state_name {lock_net} {
  if {$lock_net} {
    return "locked"
  }
  return "unlocked"
}

proc _set_net_dont_touch_flag {net_name flag quiet} {
  set net_obj [get_nets $net_name]
  if {$net_obj eq ""} {
    if {!$quiet} {
      puts "WARN: cannot resolve net object for $net_name"
    }
    return 0
  }

  if {$flag} {
    if {[catch {set_dont_touch $net_obj true} err]} {
      if {[catch {set_dont_touch $net_obj} err2]} {
        if {!$quiet} {
          puts "WARN: failed to lock net $net_name : $err / $err2"
        }
        return 0
      }
    }
  } else {
    if {[catch {set_dont_touch $net_obj false} err]} {
      if {[catch {remove_attribute $net_obj dont_touch} err2]} {
        if {[catch {reset_attribute $net_obj dont_touch} err3]} {
          if {!$quiet} {
            puts "WARN: failed to unlock net $net_name : $err / $err2 / $err3"
          }
          return 0
        }
      }
    }
  }
  return 1
}

proc _apply_net_class_optimization_mask {active_class quiet} {
  array set stats {
    upper_only_locked 0
    upper_only_unlocked 0
    bottom_only_locked 0
    bottom_only_unlocked 0
    mixed_locked 0
    mixed_unlocked 0
    unknown_locked 0
    unknown_unlocked 0
  }
  set ignore_cnt 0
  set fail_cnt 0

  foreach n [dbGet -e top.nets] {
    if {[dbGet $n.isPwrOrGnd]} {
      continue
    }

    set klass [_net_optimization_class $n]
    if {$klass eq "ignore"} {
      incr ignore_cnt
      continue
    }

    set net_name [dbGet $n.name]
    set unlock_net [_net_class_is_unlocked $active_class $klass]
    set lock_net [expr {!$unlock_net}]

    if {![_set_net_dont_touch_flag $net_name $lock_net $quiet]} {
      incr fail_cnt
      continue
    }

    set state_name [_lock_state_name $lock_net]
    set stat_key "${klass}_${state_name}"
    incr stats($stat_key)
  }

  if {!$quiet} {
    puts "INFO: Applied staged net-class mask for active_class=$active_class"
    puts "INFO:   upper_only unlocked=$stats(upper_only_unlocked) locked=$stats(upper_only_locked)"
    puts "INFO:   bottom_only unlocked=$stats(bottom_only_unlocked) locked=$stats(bottom_only_locked)"
    puts "INFO:   mixed unlocked=$stats(mixed_unlocked) locked=$stats(mixed_locked)"
    puts "INFO:   unknown unlocked=$stats(unknown_unlocked) locked=$stats(unknown_locked)"
    puts "INFO:   ignored=$ignore_cnt failures=$fail_cnt"
  }
}

proc _normalize_allow_net_class {raw_class} {
  set key [string tolower [string trim $raw_class]]
  switch -- $key {
    "" -
    "all" -
    "none" -
    "off" -
    "disabled" {
      return "all"
    }
    "upper" -
    "upper-only" -
    "upper_only" {
      return "upper_only"
    }
    "bottom" -
    "bottom-only" -
    "bottom_only" {
      return "bottom_only"
    }
    default {
      error "Unknown allow_net '$raw_class'. Use upper-only / bottom-only / all."
    }
  }
}

proc _format_allow_net_class {allow_net} {
  switch -- $allow_net {
    "upper_only" {
      return "upper-only"
    }
    "bottom_only" {
      return "bottom-only"
    }
    default {
      return "all"
    }
  }
}

proc _requested_allow_net_class {quiet} {
  set raw_class ""
  if {[info exists ::env(TIER_ALLOW_NET)]} {
    set raw_class $::env(TIER_ALLOW_NET)
  } elseif {[info exists ::env(ALLOW_NET)]} {
    set raw_class $::env(ALLOW_NET)
  }

  set active_class [_normalize_allow_net_class $raw_class]
  if {!$quiet} {
    puts "INFO: Requested allow_net '$raw_class' -> $active_class"
  }
  return $active_class
}

proc _allow_net_stage_tag {allow_net} {
  if {$allow_net eq "all"} {
    return ""
  }
  return ".[_format_allow_net_class $allow_net]"
}

# ------------------------------------------------------------
# apply_tier_policy:
# -fixlib: fix the other tier library
# -notouch: fix the other tier cell
# -allow_net: keep only one net class movable in this run
#   Allowed values:
#     upper-only / bottom-only / all
#   Behavior:
#     upper-only  -> unlock upper_only + mixed, lock bottom_only + unknown
#     bottom-only -> unlock bottom_only + mixed, lock upper_only + unknown
#     all         -> unlock upper_only + bottom_only + mixed, lock unknown
# ------------------------------------------------------------
proc apply_tier_policy {tier args} {
  set tier [string tolower $tier]
  if {![string match "upper" $tier] && ![string match "bottom" $tier]} {
    error "apply_tier_policy: tier must be 'upper' or 'bottom'"
  }

  array set opt {
    -quiet      0
    -fixlib     0
    -notouch    0
    -allow_net  all
  }

  if {([llength $args] % 2) != 0} {
    error "apply_tier_policy: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "apply_tier_policy: unknown option $k"
    }
    set opt($k) $v
  }

  set DNU_UP   [_as_list DNU_FOR_UPPER]
  set DNU_BOT  [_as_list DNU_FOR_BOTTOM]
  set FILL_UP  [_as_list FILL_CELLS_UPPER]
  set FILL_BOT [_as_list FILL_CELLS_BOTTOM]
  set TAP_UP   [_as_list TAPCELL_UPPER]
  set TAP_BOT  [_as_list TAPCELL_BOTTOM]

  if {$tier eq "upper"} {
    if {$opt(-fixlib)} {
      _set_dont_use [_expand_libcells $DNU_UP] true
    }

    if {[llength $FILL_UP]} {
      setFillerMode -core $FILL_UP
    }

    if {[info exists ::env(UPPER_SITE)] && $::env(UPPER_SITE) ne ""} {
      set ::env(PLACE_SITE) $::env(UPPER_SITE)
    }

    if {$opt(-notouch)} {
      set_dont_touch_by_ref_suffix "*_bottom" -quiet $opt(-quiet)
    }

  } else {
    if {$opt(-fixlib)} {
      _set_dont_use [_expand_libcells $DNU_BOT] true
    }

    if {[llength $FILL_BOT]} {
      setFillerMode -core $FILL_BOT
    }

    if {[info exists ::env(BOTTOM_SITE)] && $::env(BOTTOM_SITE) ne ""} {
      set ::env(PLACE_SITE) $::env(BOTTOM_SITE)
    }

    if {$opt(-notouch)} {
      set_dont_touch_by_ref_suffix "*_upper" -quiet $opt(-quiet)
    }
  }

  set allow_net [_normalize_allow_net_class $opt(-allow_net)]
  if {$allow_net ne "all"} {
    if {!$opt(-quiet)} {
      puts "INFO: Apply allow_net=[_format_allow_net_class $allow_net] for tier=$tier"
    }
    _apply_net_class_optimization_mask $allow_net $opt(-quiet)
  }

  puts "Rebuild Row for $tier"
  rebuild_rows_for_site $::env(PLACE_SITE) $tier
}
