# placement_utils.tcl
# In placement phase
# ------------------------------------------------------------
# Mark instances as a given placement status by matching master name
# Usage:
#   mark_insts_by_master "*_bottom" FIRM
#   mark_insts_by_master "" FIRM
# ------------------------------------------------------------------------------
# master_has_site: expects a dbMaster object (pointer), NOT a name string.
# ------------------------------------------------------------------------------
proc master_has_site {m} {
  # Return 1 if master is bound to a SITE (typical stdcell), else 0.
  if {![catch {set s [::odb::dbMaster_getSite $m]}]} {
    if {$s ne "" && $s ne "NULL"} { return 1 }
  }
  return 0
}

# ------------------------------------------------------------------------------
# Helper: resolve master by name (slow path). Used by name-based test API.
# ------------------------------------------------------------------------------
proc _find_master_by_name {mname} {
  set db [ord::get_db]
  set libs [::odb::dbDatabase_getLibs $db]
  foreach lib $libs {
    set masters [::odb::dbLib_getMasters $lib]
    foreach m $masters {
      if {[$m getName] eq $mname} { return $m }
    }
  }
  return ""
}

# ------------------------------------------------------------------------------
# Name-based test API (for your colleague): master_has_site_by_name "CELLNAME"
# Uses cache to avoid repeated library scans.
# ------------------------------------------------------------------------------
proc master_has_site_by_name {mname} {
  # Cache: ::_MASTER_HAS_SITE_CACHE($mname) => 0/1
  if {[info exists ::_MASTER_HAS_SITE_CACHE($mname)]} {
    return $::_MASTER_HAS_SITE_CACHE($mname)
  }
  set m [_find_master_by_name $mname]
  if {$m eq ""} {
    set ::_MASTER_HAS_SITE_CACHE($mname) 0
    return 0
  }
  set v [master_has_site $m]
  set ::_MASTER_HAS_SITE_CACHE($mname) $v
  return $v
}

proc mark_insts_by_master {{pattern ""} {status "FIRM"}} {
  # 1) Parse pattern
  if {$pattern eq ""} {
    return 0
  }

  # 2) Validate target status (common OpenROAD/ODB values)
  set valid_status {UNPLACED PLACED FIRM LOCKED FIXED}
  if {[lsearch -exact $valid_status $status] < 0} {
    puts "WARN: '$status' not in valid statuses: $valid_status ; fallback to FIRM"
    set status FIRM
  }

  # 3) Get DB/Block
  set db   [ord::get_db]
  set chip [$db getChip]
  if {$chip eq ""} {
    puts "WARN: No chip loaded."
    return 0
  }
  set block [$chip getBlock]
  if {$block eq ""} {
    puts "WARN: No block in chip."
    return 0
  }

  # 4) Iterate instances; match by master name and set status
  set cnt 0
  set examples {}
  foreach inst [$block getInsts] {
    set mname [[$inst getMaster] getName]
    # if master have site, it is CORE CELL
    if {[master_has_site_by_name $mname]} {
      if {[string match -nocase $pattern $mname]} {
        if {[catch {$inst setPlacementStatus $status} err]} {
          puts "WARN: fail to set $status for [$inst getName]($mname): $err"
        } else {
          incr cnt
          if {[llength $examples] < 5} {
            lappend examples "[$inst getName]($mname)"
          }
        }
      }
    }
  }

  puts "INFO: Marked $cnt insts to '$status' by master pattern '$pattern'. Examples: [join $examples {, }]"
  return $cnt
}

# Helpers
proc ::_as_int {v default} {
  if {![info exists v]} { return $default }
  if {![string is integer -strict $v]} { return $default }
  return $v
}

proc ::_env_or {name default} {
  if {[info exists ::env($name)]} { return $::env($name) }
  return $default
}

# Recursively print all commands and child namespaces under a namespace
proc or_list_ns_cmds {ns {indent ""}} {
  # Print current namespace
  puts "${indent}Namespace: $ns"

  # Commands under current namespace (matched by pattern)
  set pattern "${ns}::*"
  set cmds [lsort [info commands $pattern]]
  foreach c $cmds {
    puts "${indent}  [string range $c 0 end]"
  }

  # Recursively traverse child namespaces
  set children [lsort [namespace children $ns]]
  foreach child $children {
    or_list_ns_cmds $child "${indent}  "
  }
}

# Robust density calculator
proc calculate_placement_density {} {
  set base_density [::_env_or PLACE_DENSITY 0.60]

  # 1) If no addon requested, just use base
  if {![info exists ::env(PLACE_DENSITY_LB_ADDON)]} {
    puts "INFO: PLACE_DENSITY_LB_ADDON not set, using PLACE_DENSITY=$base_density"
    return $base_density
  }

  # 3) Pad arguments must be integers; default to 0 if missing
  set pad_l [::_as_int $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) 0]
  set pad_r [::_as_int $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) 0]
  # 4) Compute LB with catch to absorb GPL-0301 on older builds / invalid states 
  set lb 0.0
  set rc [catch {
    set lb [gpl::get_global_placement_uniform_density -pad_left $pad_l -pad_right $pad_r]
  } err]

  if {$rc} {
    puts "ERRORINFO:\n$::errorInfo"
    return $base_density
  }

  # 5) Apply addon blend and a tiny nudge
  set addon $::env(PLACE_DENSITY_LB_ADDON)
  if {$addon < 0.0} { set addon 0.0 }
  if {$addon > 1.0} { set addon 1.0 }

  set density [expr {$lb + ((1.0 - $lb) * $addon) + 0.01}]
  if {$density <= 0.0} { set density 0.10 }
  if {$density >= 1.0} { set density 0.98 }

  puts "INFO: PLACE_DENSITY_LB=$lb, ADDON=$addon -> density=$density (padL=$pad_l padR=$pad_r)"
  return $density
}

# Utility: delete instances by matching master name
# pattern default "*_bottom*"; dry_run=1 only prints; verbose controls logging
proc delete_insts_by_master {{pattern ""} {dry_run 0} {verbose 1}} {
  set db   [ord::get_db]
  set chip [$db getChip]
  if {$chip eq ""} { puts "WARN: no chip"; return 0 }
  set block [$chip getBlock]
  if {$block eq ""} { puts "WARN: no block"; return 0 }
  
  if {$pattern eq ""} {
  puts "WARN: empty pattern, skip."
  return 0
  }
  set del_names {}
  foreach inst [$block getInsts] {
  set mname [[$inst getMaster] getName]
  if {[string match -nocase $pattern $mname]} {
    lappend del_names [$inst getName]
  }
  }

  if {$verbose} {
  puts "INFO: matched [llength $del_names] insts by master '$pattern'"
  puts "INFO: examples: [join [lrange $del_names 0 9] {, }]"
  }

  if {$dry_run} { return [llength $del_names] }

  set ok 0
  foreach name $del_names {
  if {[catch {delete_instance $name} err]} {
    puts "WARN: delete_instance $name failed: $err"
  } else {
    incr ok
  }
  }
  if {$verbose} { puts "INFO: actually deleted $ok insts." }
  return $ok
}

# ------------------------------------------------------------
# OpenROAD: dont_use & FastRoute
# ------------------------------------------------------------
# Get environment variable as list (missing/empty => {})
proc _as_list {envname} {
  if {[info exists ::env($envname)] && $::env($envname) ne ""} {
  return $::env($envname)
  }
  return {}
}

# Expand wildcard patterns to real lib cell names; keep original if command unsupported
proc _expand_libcells {patterns} {
  set out {}
  foreach p $patterns {
    # 1. Try to find cells matching the pattern
    if {![catch {set hits [get_lib_cells $p]}]} {
      if {[llength $hits] > 0} {
        foreach h $hits { 
          lappend out [::sta::LibertyCell_name $h] 
        }
        continue
      }
    }
  }
  return [lsort -unique $out]
}

# set_dont_use prefers batch; if it fails, fall back to per-cell
proc _set_dont_use {cells} {
  # puts "_set_dont_use $cells"
  if {![llength $cells]} { return }
  foreach c $cells { 
    set_dont_use $c 
    puts "set_dont_use $c"
  }
}

# FastRoute fallback setup (can be overridden by external Tcl)
proc fastroute_setup {} {
  # Prefer user-provided external script
  if {[info exists ::env(FASTROUTE_TCL)] && $::env(FASTROUTE_TCL) ne ""} {
  puts "INFO(OR): Sourcing FASTROUTE_TCL = $::env(FASTROUTE_TCL)"
  catch { source $::env(FASTROUTE_TCL) }
  return
  }

  # Fallback: set signal layers and congestion adjustment from MIN/MAX_ROUTING_LAYER
  set minL [expr {[info exists ::env(MIN_ROUTING_LAYER)] ? $::env(MIN_ROUTING_LAYER) : "met1"}]
  set maxL [expr {[info exists ::env(MAX_ROUTING_LAYER)] ? $::env(MAX_ROUTING_LAYER) : "met5"}]

  catch { set_routing_layers -signal ${minL}-${maxL} }
  # Apply uniform layer adjustment (more conservative congestion); can be refined per-layer
  catch { set_global_routing_layer_adjustment ${minL}-${maxL} 0.5 }

  puts "INFO(OR): FastRoute default setup done: layers=${minL}-${maxL}, adjust=0.5"
}

# ============================================================
# Row rebuild for OpenROAD (site-snapped + die-clamped)
# ============================================================
proc _snap_down_dbu {x pitch} {
  if {$pitch <= 0} { error "ERROR: pitch must be > 0, got $pitch" }
  return [expr {($x / $pitch) * $pitch}]   ;# floor to pitch grid
}

proc _snap_up_dbu {x pitch} {
  if {$pitch <= 0} { error "ERROR: pitch must be > 0, got $pitch" }
  if {$x % $pitch == 0} { return $x }
  return [expr {(($x / $pitch) + 1) * $pitch}]  ;# ceil to pitch grid
}

proc _clamp_dbu {x lo hi} {
  if {$x < $lo} { return $lo }
  if {$x > $hi} { return $hi }
  return $x
}

# Get die area in DBU: {lx ly ux uy}
proc or_get_die_area_dbu {block} {
  lassign [ord::get_die_area] dlx_um dly_um dux_um duy_um
  return [list \
    [$block micronsToDbu $dlx_um] \
    [$block micronsToDbu $dly_um] \
    [$block micronsToDbu $dux_um] \
    [$block micronsToDbu $duy_um] \
  ]
}

# Find a dbSite by name from any library in the current db. (must find or error)
proc or_find_site_by_name_in_db {site_name} {
  set db [ord::get_db]
  foreach lib [$db getLibs] {
    set s [odb::dbLib_findSite $lib $site_name]
    if {$s ne "" && $s ne "NULL"} { return $s }
  }
  error "ERROR: cannot resolve site '$site_name' via odb::dbLib_findSite in any dbLib."
}

proc or_rebuild_rows_for_site {new_site tier} {
  # die area (microns): {lx ly ux uy}
  lassign [ord::get_die_area] die_lx die_ly die_ux die_uy

  # core margin (microns)
  set m 0.0
  if {[info exists ::env(CORE_MARGIN)] && $::env(CORE_MARGIN) ne ""} {
    set m [expr {double($::env(CORE_MARGIN))}]
  }
  if {$m < 0.0} {
    error "ERROR: CORE_MARGIN must be >= 0, got $m"
  }

  # core area = die area inset by margin
  set core_lx [expr {$die_lx + $m}]
  set core_ly [expr {$die_ly + $m}]
  set core_ux [expr {$die_ux - $m}]
  set core_uy [expr {$die_uy - $m}]

  if {$core_ux <= $core_lx || $core_uy <= $core_ly} {
    error "ERROR: CORE_MARGIN ($m um) too large for die_area {$die_lx $die_ly $die_ux $die_uy}"
  }

  # deterministic: site must exist in dbLib 
  set site [or_find_site_by_name_in_db $new_site]
  if {[$site getWidth] <= 0 || [$site getHeight] <= 0} {
    error "ERROR: invalid site '$new_site' (w=[$site getWidth] h=[$site getHeight])"
  }
  if { [find_macros] != "" } {
    lassign $::env(MACRO_PLACE_HALO) halo_x halo_y
    set halo_max [expr max($halo_x, $halo_y)]
    set blockage_width $halo_max
    source $::env(OPENROAD_SCRIPTS_DIR)/placement_blockages.tcl
    clear_channels
    block_channels $blockage_width $tier
  }
  # make_rows will rebuild rows (and clear existing ones internally)
  make_rows -core_area [list $core_lx $core_ly $core_ux $core_uy] -site $new_site
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
    "upper_only" { return "upper-only" }
    "bottom_only" { return "bottom-only" }
    default { return "all" }
  }
}

proc _or_pin3d_flow_switch_mode {env_name default_mode} {
  set raw_value $default_mode
  if {[info exists ::env($env_name)] && $::env($env_name) ne ""} {
    set raw_value $::env($env_name)
  }
  set key [string tolower [string trim $raw_value]]
  switch -- $key {
    "" -
    "1" -
    "on" -
    "true" -
    "yes" -
    "enabled" {
      return "on"
    }
    "0" -
    "off" -
    "false" -
    "no" -
    "disabled" {
      return "off"
    }
    default {
      error "Unknown ${env_name} value '$raw_value'. Use on/off."
    }
  }
}

proc pin3d_allow_net_flow_mode {} {
  return [_or_pin3d_flow_switch_mode "PIN3D_ALLOW_NET_FLOW" "on"]
}

proc pin3d_allow_net_flow_enabled {} {
  expr {[pin3d_allow_net_flow_mode] eq "on"}
}

proc pin3d_split_net_flow_mode {} {
  return [_or_pin3d_flow_switch_mode "PIN3D_SPLIT_NET_FLOW" "on"]
}

proc pin3d_split_net_flow_enabled {} {
  expr {[pin3d_split_net_flow_mode] eq "on"}
}

proc or_cts_owner_tier {} {
  set cts_layer "bottom"
  if {[info exists ::env(CTS_LAYER)] && $::env(CTS_LAYER) ne ""} {
    set cts_layer [string tolower $::env(CTS_LAYER)]
  }
  if {$cts_layer ne "upper" && $cts_layer ne "bottom"} {
    error "CTS_LAYER must be upper or bottom, got '$cts_layer'"
  }
  return $cts_layer
}

proc or_cts_fix_tier {} {
  if {[or_cts_owner_tier] eq "upper"} {
    return "bottom"
  }
  return "upper"
}

proc _requested_allow_net_class_with_default {default_class quiet} {
  set raw_class $default_class
  if {[info exists ::env(TIER_ALLOW_NET)] && $::env(TIER_ALLOW_NET) ne ""} {
    set raw_class $::env(TIER_ALLOW_NET)
  } elseif {[info exists ::env(ALLOW_NET)] && $::env(ALLOW_NET) ne ""} {
    set raw_class $::env(ALLOW_NET)
  }

  set active_class [_normalize_allow_net_class $raw_class]
  if {!$quiet} {
    puts "INFO(OR): Requested allow_net '$raw_class' -> $active_class"
  }
  return $active_class
}

proc _effective_allow_net_class {requested_class {quiet 0}} {
  set requested_class [_normalize_allow_net_class $requested_class]
  if {![pin3d_allow_net_flow_enabled]} {
    if {!$quiet} {
      puts "INFO(OR): PIN3D_ALLOW_NET_FLOW=off -> force allow_net all"
    }
    return "all"
  }
  return $requested_class
}

proc _report_allow_net_resolution {stage_label requested_class effective_class} {
  puts "INFO(OR): ${stage_label} PIN3D_ALLOW_NET_FLOW=[pin3d_allow_net_flow_mode] requested_allow_net=[_format_allow_net_class $requested_class] effective_allow_net=[_format_allow_net_class $effective_class]"
}

proc _or_is_split_buffer_name {name} {
  set trimmed [string trim $name]
  if {[string match "*__PIN3DSPLITBUF__*" $trimmed]} {
    return 1
  }
  # Backward compatibility for older result variants.
  return [expr {[string match "*SPLITBUF*" $trimmed]}]
}

proc _pin3d_split_buffer_cells {} {
  array set seen {}
  set cells {}
  foreach pattern [list "*__PIN3DSPLITBUF__*" "*__SPLITBUF*"] {
    foreach cell_obj [get_cells -hierarchical -quiet $pattern] {
      if {[info exists seen($cell_obj)]} {
        continue
      }
      set seen($cell_obj) 1
      lappend cells $cell_obj
    }
  }
  return $cells
}

proc _protect_pin3d_split_buffers {quiet {protect 1}} {
  set split_cells [_pin3d_split_buffer_cells]
  set touched 0
  set failures 0
  foreach cell_obj $split_cells {
    if {$protect} {
      if {[catch {set_dont_touch $cell_obj} err]} {
        incr failures
        if {!$quiet} {
          puts "WARN(OR): failed to protect PIN3D split buffer $cell_obj : $err"
        }
        continue
      }
    } else {
      if {[catch {unset_dont_touch $cell_obj} err]} {
        incr failures
        if {!$quiet} {
          puts "WARN(OR): failed to unprotect PIN3D split buffer $cell_obj : $err"
        }
        continue
      }
    }
    incr touched
  }
  if {!$quiet} {
    if {$protect} {
      puts "INFO(OR): Protected PIN3D split buffers count=$touched failures=$failures"
    } else {
      puts "INFO(OR): Unprotected PIN3D split buffers count=$touched failures=$failures"
    }
  }
  return $touched
}

proc _or_inst_tier {inst} {
  set master [$inst getMaster]
  set mname [$master getName]
  set iname [$inst getName]
  if {[_or_is_split_buffer_name $mname] || [_or_is_split_buffer_name $iname]} {
    return "split_buffer"
  }
  if {[string match -nocase "*_upper" $mname]} {
    return "upper"
  }
  if {[string match -nocase "*_bottom" $mname] || [string match -nocase "*_lower" $mname]} {
    return "bottom"
  }
  return "unknown"
}

proc _net_tier_presence {net_ptr} {
  set upper_count 0
  set bottom_count 0
  set unknown_count 0

  foreach it [$net_ptr getITerms] {
    set mt [$it getMTerm]
    if {[catch {set st [$mt getSigType]}]} {
      set st "SIGNAL"
    }
    if {$st eq "POWER" || $st eq "GROUND"} {
      continue
    }

    set tier [_or_inst_tier [$it getInst]]
    switch -- $tier {
      upper   { incr upper_count }
      bottom  { incr bottom_count }
      split_buffer { continue }
      default { incr unknown_count }
    }
  }

  return [list $upper_count $bottom_count $unknown_count]
}

proc _or_layer_to_tier {layer_name} {
  set layer_name [string trim $layer_name]
  if {$layer_name eq ""} {
    return "unknown"
  }

  set lname [string tolower $layer_name]
  if {$lname eq "hb_layer"} {
    return "unknown"
  }
  if {[string match "via*" $lname]} {
    return "unknown"
  }
  if {[string match "*_m" $lname]} {
    return "upper"
  }
  return "bottom"
}

proc _or_bterm_routing_layers {bterm_ptr} {
  set layers {}
  if {$bterm_ptr eq ""} {
    return $layers
  }

  if {[catch {set bpins [$bterm_ptr getBPins]}]} {
    return $layers
  }
  foreach bpin $bpins {
    if {[catch {set boxes [$bpin getBoxes]}]} {
      continue
    }
    foreach box $boxes {
      if {[catch {set layer [$box getTechLayer]}]} {
        continue
      }
      if {$layer eq "" || $layer eq "NULL"} {
        continue
      }
      if {[catch {set layer_name [$layer getName]}]} {
        continue
      }
      if {$layer_name eq ""} {
        continue
      }
      lappend layers $layer_name
    }
  }
  return [lsort -unique $layers]
}

proc _or_bterm_tier {bterm_ptr} {
  set has_upper 0
  set has_bottom 0
  foreach layer [_or_bterm_routing_layers $bterm_ptr] {
    switch -- [_or_layer_to_tier $layer] {
      upper {
        set has_upper 1
      }
      bottom {
        set has_bottom 1
      }
      default {
      }
    }
  }

  if {$has_upper && !$has_bottom} {
    return "upper"
  }
  if {$has_bottom && !$has_upper} {
    return "bottom"
  }
  return "unknown"
}

proc tier_net_presence_detail_counts {net_ptr} {
  set upper_count 0
  set bottom_count 0
  set io_count 0
  set unknown_count 0

  foreach it [$net_ptr getITerms] {
    set mt [$it getMTerm]
    if {[catch {set st [$mt getSigType]}]} {
      set st "SIGNAL"
    }
    if {$st eq "POWER" || $st eq "GROUND"} {
      continue
    }

    set tier [_or_inst_tier [$it getInst]]
    switch -- $tier {
      upper   { incr upper_count }
      bottom  { incr bottom_count }
      split_buffer { continue }
      default { incr unknown_count }
    }
  }

  if {![catch {set bterms [$net_ptr getBTerms]}]} {
    foreach bterm $bterms {
      if {[catch {set st [$bterm getSigType]}]} {
        set st "SIGNAL"
      }
      if {$st eq "POWER" || $st eq "GROUND"} {
        continue
      }
      incr io_count
      switch -- [_or_bterm_tier $bterm] {
        upper {
          incr upper_count
        }
        bottom {
          incr bottom_count
        }
        default {
          incr unknown_count
        }
      }
    }
  }

  return [list $upper_count $bottom_count $io_count $unknown_count]
}

proc _cross_tier_category_from_presence {has_upper has_bottom has_io has_unknown} {
  if {$has_upper && $has_bottom && $has_io} {
    return "Upper_Bottom_IO"
  }
  if {$has_upper && $has_bottom} {
    return "Upper_Bottom"
  }
  if {$has_upper && $has_io} {
    return "Upper_IO"
  }
  if {$has_bottom && $has_io} {
    return "Bottom_IO"
  }
  if {$has_unknown} {
    return "Unknown_Tier"
  }
  return ""
}

proc extract_cross_tier_net_stats {list_rpt_path args} {
  array set opt {
    -clock_only 0
  }
  if {([llength $args] % 2) != 0} {
    error "extract_cross_tier_nets: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "extract_cross_tier_nets: unknown option $k"
    }
    set opt($k) $v
  }

  set total_cross_tier 0
  array set category_counts {
    Upper_Bottom    0
    Upper_IO        0
    Bottom_IO       0
    Upper_Bottom_IO 0
    Unknown_Tier    0
  }

  set report_lines [list "# Cross-Tier Net Report"]
  lappend report_lines [format "%-40s | %s" "Net Name" "Type"]
  lappend report_lines "-----------------------------------------|------------------"

  array set clock_net_lookup {}
  if {$opt(-clock_only)} {
    foreach clock_net_name [_clock_net_name_set] {
      set clock_net_lookup($clock_net_name) 1
    }
  }

  set block [ord::get_db_block]
  foreach net [$block getNets] {
    set sig_type [$net getSigType]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    if {$opt(-clock_only) && ![info exists clock_net_lookup([$net getName])]} {
      continue
    }

    lassign [tier_net_presence_detail_counts $net] upper_count bottom_count io_count unknown_count
    set has_upper [expr {$upper_count > 0}]
    set has_bottom [expr {$bottom_count > 0}]
    set has_io [expr {$io_count > 0}]
    set has_unknown [expr {$unknown_count > 0}]
    set net_type [_cross_tier_category_from_presence $has_upper $has_bottom $has_io $has_unknown]

    if {$net_type ne ""} {
      if {$net_type ne "Unknown_Tier"} {
        incr total_cross_tier
      }
      incr category_counts($net_type)
      lappend report_lines [format "%-40s | %s" [$net getName] $net_type]
    }
  }

  lappend report_lines ""
  lappend report_lines [format "Total Cross-Tier Nets: %d" $total_cross_tier]
  lappend report_lines "Category Totals:"
  foreach key {Upper_Bottom Upper_IO Bottom_IO Upper_Bottom_IO Unknown_Tier} {
    lappend report_lines [format "  %-18s %d" $key $category_counts($key)]
  }

  if {$list_rpt_path ne ""} {
    set fh [open $list_rpt_path w]
    foreach line $report_lines {
      puts $fh $line
    }
    close $fh
  }

  return [dict create \
    cross_tier_all $total_cross_tier \
    upper_bottom $category_counts(Upper_Bottom) \
    upper_io $category_counts(Upper_IO) \
    bottom_io $category_counts(Bottom_IO) \
    upper_bottom_io $category_counts(Upper_Bottom_IO) \
    unknown $category_counts(Unknown_Tier)]
}

proc extract_cross_tier_nets {list_rpt_path args} {
  return [dict get [extract_cross_tier_net_stats $list_rpt_path {*}$args] cross_tier_all]
}

proc _cross_tier_stats_brief {stats} {
  return [format "all=%d UB=%d UIO=%d BIO=%d UBIO=%d UNK=%d" \
    [dict get $stats cross_tier_all] \
    [dict get $stats upper_bottom] \
    [dict get $stats upper_io] \
    [dict get $stats bottom_io] \
    [dict get $stats upper_bottom_io] \
    [dict get $stats unknown]]
}

proc _read_cross_tier_report_stats {report_path} {
  if {$report_path eq "" || ![file exists $report_path]} {
    return ""
  }

  set stats [dict create \
    cross_tier_all 0 \
    upper_bottom 0 \
    upper_io 0 \
    bottom_io 0 \
    upper_bottom_io 0 \
    unknown 0]

  set fh [open $report_path r]
  while {[gets $fh line] >= 0} {
    if {[regexp {^Total Cross-Tier Nets:\s+([0-9]+)} $line -> value]} {
      dict set stats cross_tier_all $value
      continue
    }
    if {[regexp {^\s*Upper_Bottom\s+([0-9]+)} $line -> value]} {
      dict set stats upper_bottom $value
      continue
    }
    if {[regexp {^\s*Upper_IO\s+([0-9]+)} $line -> value]} {
      dict set stats upper_io $value
      continue
    }
    if {[regexp {^\s*Bottom_IO\s+([0-9]+)} $line -> value]} {
      dict set stats bottom_io $value
      continue
    }
    if {[regexp {^\s*Upper_Bottom_IO\s+([0-9]+)} $line -> value]} {
      dict set stats upper_bottom_io $value
      continue
    }
    if {[regexp {^\s*Unknown_Tier\s+([0-9]+)} $line -> value]} {
      dict set stats unknown $value
      continue
    }
  }
  close $fh
  return $stats
}

proc report_cross_tier_snapshot {report_path args} {
  array set opt {
    -label ""
    -clock_only 0
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_cross_tier_snapshot: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_cross_tier_snapshot: unknown option $k"
    }
    set opt($k) $v
  }

  set stats [extract_cross_tier_net_stats $report_path -clock_only $opt(-clock_only)]
  if {!$opt(-quiet)} {
    set label $opt(-label)
    if {$label eq ""} {
      set label [file tail $report_path]
    }
    puts "INFO(OR): cross-tier snapshot $label [_cross_tier_stats_brief $stats]"
  }
  return $stats
}

proc report_cross_tier_transition {summary_path before_report after_report args} {
  array set opt {
    -label ""
    -clock_only 0
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_cross_tier_transition: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_cross_tier_transition: unknown option $k"
    }
    set opt($k) $v
  }

  set before_stats [_read_cross_tier_report_stats $before_report]
  if {$before_stats eq ""} {
    set before_stats [report_cross_tier_snapshot $before_report -label "${opt(-label)} before" -clock_only $opt(-clock_only) -quiet $opt(-quiet)]
  } elseif {!$opt(-quiet)} {
    puts "INFO(OR): cross-tier snapshot ${opt(-label)} before [_cross_tier_stats_brief $before_stats]"
  }
  set after_stats  [report_cross_tier_snapshot $after_report  -label "${opt(-label)} after"  -clock_only $opt(-clock_only) -quiet $opt(-quiet)]

  if {!$opt(-quiet)} {
    set before_all [dict get $before_stats cross_tier_all]
    set after_all [dict get $after_stats cross_tier_all]
    puts "INFO(OR): cross-tier transition $opt(-label) before=$before_all after=$after_all delta=[expr {$after_all - $before_all}]"
  }

  if {$summary_path ne ""} {
    set fh [open $summary_path w]
    puts $fh [format "label %s" $opt(-label)]
    puts $fh [format "clock_only %d" $opt(-clock_only)]
    foreach {tag stats} [list before $before_stats after $after_stats] {
      puts $fh "$tag [_cross_tier_stats_brief $stats]"
      puts $fh [format "%s_cross_tier_all %d" $tag [dict get $stats cross_tier_all]]
      puts $fh [format "%s_upper_bottom %d" $tag [dict get $stats upper_bottom]]
      puts $fh [format "%s_upper_io %d" $tag [dict get $stats upper_io]]
      puts $fh [format "%s_bottom_io %d" $tag [dict get $stats bottom_io]]
      puts $fh [format "%s_upper_bottom_io %d" $tag [dict get $stats upper_bottom_io]]
      puts $fh [format "%s_unknown %d" $tag [dict get $stats unknown]]
    }
    puts $fh [format "delta_cross_tier_all %d" [expr {[dict get $after_stats cross_tier_all] - [dict get $before_stats cross_tier_all]}]]
    close $fh
  }

  return [dict create before $before_stats after $after_stats]
}

proc _net_optimization_class {net_ptr} {
  lassign [tier_net_presence_detail_counts $net_ptr] upper_count bottom_count io_count unknown_count
  set has_upper [expr {$upper_count > 0}]
  set has_bottom [expr {$bottom_count > 0}]
  set has_unknown [expr {$unknown_count > 0}]

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
  if {$io_count > 0} {
    return "ignore"
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

proc _set_net_dont_touch_flag {net_name flag quiet} {
  set net_obj [get_nets -quiet $net_name]
  if {$net_obj eq ""} {
    if {!$quiet} {
      puts "WARN(OR): cannot resolve net object for $net_name"
    }
    return 0
  }

  if {$flag} {
    if {[catch {set_dont_touch $net_obj} err]} {
      if {!$quiet} {
        puts "WARN(OR): failed to lock net $net_name : $err"
      }
      return 0
    }
  } else {
    if {[catch {unset_dont_touch $net_obj} err]} {
      if {!$quiet} {
        puts "WARN(OR): failed to unlock net $net_name : $err"
      }
      return 0
    }
  }
  return 1
}

proc _clock_port_name_candidates {{sdc_path ""}} {
  array set seen {}
  set out {}

  foreach var_name {::clk_port_name clk_port_name} {
    if {[uplevel #0 [list info exists $var_name]]} {
      set port_name [uplevel #0 [list set $var_name]]
      if {$port_name ne "" && $port_name ne "NULL" && ![info exists seen($port_name)]} {
        set seen($port_name) 1
        lappend out $port_name
      }
    }
  }

  foreach env_name {CLOCK_PORT CLK_PORT_NAME CLK_PORT} {
    if {[info exists ::env($env_name)] && $::env($env_name) ne ""} {
      foreach port_name $::env($env_name) {
        if {$port_name ne "" && $port_name ne "NULL" && ![info exists seen($port_name)]} {
          set seen($port_name) 1
          lappend out $port_name
        }
      }
    }
  }

  if {$sdc_path ne "" && [file exists $sdc_path]} {
    set fp [open $sdc_path r]
    while {[gets $fp line] >= 0} {
      if {[regexp {^\s*set\s+clk_port_name\s+([^\s#;]+)} $line -> port_name]} {
        if {$port_name ne "" && $port_name ne "NULL" && ![info exists seen($port_name)]} {
          set seen($port_name) 1
          lappend out $port_name
        }
      }
      if {[regexp {create_clock.*\[get_ports\s+([^\]\s]+)\]} $line -> port_name]} {
        if {[string index $port_name 0] eq "$"} {
          continue
        }
        if {$port_name ne "" && $port_name ne "NULL" && ![info exists seen($port_name)]} {
          set seen($port_name) 1
          lappend out $port_name
        }
      }
    }
    close $fp
  }

  return $out
}

proc _clock_net_name_set {{sdc_path ""}} {
  array set clock_names {}
  foreach port_name [_clock_port_name_candidates $sdc_path] {
    set nets {}
    if {![catch {set nets [get_nets -quiet $port_name]}] && [llength $nets] > 0} {
      # prefer direct net lookup because some OpenROAD builds reject Port objects
    } elseif {![catch {set port_obj [get_ports $port_name]}] && [llength $port_obj] > 0} {
      catch {set nets [get_nets -quiet -of_objects $port_obj]}
    }
    if {[llength $nets] == 0} {
      continue
    }
    foreach net_obj $nets {
      if {[catch {set net_name [get_name $net_obj]}] || $net_name eq "" || $net_name eq "NULL"} {
        continue
      }
      set clock_names($net_name) 1
    }
  }

  if {[array size clock_names] > 0} {
    return [array names clock_names]
  }

  foreach clock [all_clocks] {
    if {$clock eq "" || $clock eq "NULL"} {
      continue
    }
    set clock_obj $clock
    if {![catch {set maybe_name [get_name $clock]}] && $maybe_name ne "" && $maybe_name ne "NULL"} {
      set clock_obj $maybe_name
    }
    if {[catch {set sources [get_property -object_type clock $clock_obj sources]}] || [llength $sources] == 0} {
      continue
    }
    set clean_sources {}
    foreach src $sources {
      if {$src eq "" || $src eq "NULL"} {
        continue
      }
      lappend clean_sources $src
    }
    if {[llength $clean_sources] == 0} {
      continue
    }
    if {[catch {set nets [get_nets -quiet -of_objects $clean_sources]}]} {
      continue
    }
    foreach net_obj $nets {
      if {[catch {set net_name [get_name $net_obj]}] || $net_name eq ""} {
        continue
      }
      set clock_names($net_name) 1
    }
  }
  return [array names clock_names]
}

proc _apply_net_class_optimization_mask {active_class quiet {skip_clock_nets 0}} {
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
  set clock_skip_cnt 0

  array set clock_net_lookup {}
  if {$skip_clock_nets} {
    foreach clock_net_name [_clock_net_name_set] {
      set clock_net_lookup($clock_net_name) 1
    }
  }

  set block [ord::get_db_block]
  foreach net [$block getNets] {
    set sig_type [$net getSigType]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }

    set klass [_net_optimization_class $net]
    if {$klass eq "ignore"} {
      incr ignore_cnt
      continue
    }

    set net_name [$net getName]
    if {$skip_clock_nets && [info exists clock_net_lookup($net_name)]} {
      if {![_set_net_dont_touch_flag $net_name 0 $quiet]} {
        incr fail_cnt
      } else {
        incr clock_skip_cnt
      }
      continue
    }
    set unlock_net [_net_class_is_unlocked $active_class $klass]
    set lock_net [expr {!$unlock_net}]
    if {![_set_net_dont_touch_flag $net_name $lock_net $quiet]} {
      incr fail_cnt
      continue
    }

    if {$lock_net} {
      incr stats(${klass}_locked)
    } else {
      incr stats(${klass}_unlocked)
    }
  }

  if {!$quiet} {
    puts "INFO(OR): Applied staged net-class mask for active_class=$active_class"
    puts "INFO(OR):   upper_only unlocked=$stats(upper_only_unlocked) locked=$stats(upper_only_locked)"
    puts "INFO(OR):   bottom_only unlocked=$stats(bottom_only_unlocked) locked=$stats(bottom_only_locked)"
    puts "INFO(OR):   mixed unlocked=$stats(mixed_unlocked) locked=$stats(mixed_locked)"
    puts "INFO(OR):   unknown unlocked=$stats(unknown_unlocked) locked=$stats(unknown_locked)"
    puts "INFO(OR):   ignored=$ignore_cnt clock_skipped=$clock_skip_cnt failures=$fail_cnt"
  }
}

# ------------------------------------------------------------
# Apply tier policy
# Options:
#   -quiet 0/1 (default 0)
# ------------------------------------------------------------
proc apply_tier_policy {tier args} {
  set tier [string tolower $tier]
  if {$tier ne "upper" && $tier ne "bottom"} {
    error "apply_tier_policy: tier must be 'upper' or 'bottom'"
  }

  array set opt {
    -quiet    0
    -fixlib   0
    -allow_net all
    -rebuild_rows 1
    -skip_clock_nets 0
    -protect_split_buffers 1
  }
  if {([llength $args] % 2) != 0} {
    error "apply_tier_policy: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} { error "apply_tier_policy: unknown option $k" }
    set opt($k) $v
  }

  set dnu_up  [_as_list DNU_FOR_UPPER]
  set dnu_bot [_as_list DNU_FOR_BOTTOM]
  set requested_allow_net [_requested_allow_net_class_with_default $opt(-allow_net) $opt(-quiet)]
  set effective_allow_net [_effective_allow_net_class $requested_allow_net $opt(-quiet)]
  _report_allow_net_resolution "tier_policy/${tier}" $requested_allow_net $effective_allow_net

  if {$tier eq "upper"} {
    # dont_use for synthesis/placement choices
    if {$opt(-fixlib)} { 
      _set_dont_use [_expand_libcells $dnu_up] 
    }

    set ::env(TIEHI_CELL_AND_PORT) $::env(UPPER_TIEHI_CELL_AND_PORT)
    set ::env(TIELO_CELL_AND_PORT) $::env(UPPER_TIELO_CELL_AND_PORT)
    if {[info exists ::env(UPPER_SITE)]} { set ::env(PLACE_SITE) $::env(UPPER_SITE) }

    if {!$opt(-quiet)} {
      puts "INFO(OR): Tier=UPPER applied."
    }
  } else {
    if {$opt(-fixlib)} { 
      _set_dont_use [_expand_libcells $dnu_bot] 
    }

    set ::env(TIEHI_CELL_AND_PORT) $::env(BOTTOM_TIEHI_CELL_AND_PORT)
    set ::env(TIELO_CELL_AND_PORT) $::env(BOTTOM_TIELO_CELL_AND_PORT)
    if {[info exists ::env(BOTTOM_SITE)]} { set ::env(PLACE_SITE) $::env(BOTTOM_SITE) }

    if {!$opt(-quiet)} {
      puts "INFO(OR): Tier=BOTTOM applied."
    }
  }

  if {[info exists ::env(DONT_USE_CELLS)] && $::env(DONT_USE_CELLS) ne ""} {
    _set_dont_use [_expand_libcells $::env(DONT_USE_CELLS)]
    if {!$opt(-quiet)} { puts "INFO(OR): Applied DONT_USE_CELLS = '$::env(DONT_USE_CELLS)'." }
  }

  _protect_pin3d_split_buffers $opt(-quiet) $opt(-protect_split_buffers)
  _apply_net_class_optimization_mask $effective_allow_net $opt(-quiet) $opt(-skip_clock_nets)
  if {$opt(-rebuild_rows)} {
    or_rebuild_rows_for_site $::env(PLACE_SITE) $tier
  }
}
