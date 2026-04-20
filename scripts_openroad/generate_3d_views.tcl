# ============================================================
# generate_3d_views.tcl
# Generate 3D DEF/Verilog views natively inside OpenROAD/ODB.
# ============================================================

source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/json_lite.tcl

namespace eval ::pin3d {
  # Temporary names used while recreating instances and reconnecting nets.
  variable tmp_inst_idx 0
}

# ----------------------------------------------------------------------
# Logging and naming helpers
# ----------------------------------------------------------------------

proc ::pin3d::log {msg} {
  puts "INFO(PIN3D): $msg"
}

proc ::pin3d::warn {msg} {
  puts "WARN(PIN3D): $msg"
}

proc ::pin3d::normalize_name {name} {
  set t [string trim $name]
  if {[string index $t 0] eq "\\"} {
    set t [string range $t 1 end]
  }
  set t [string map [list {\/} {/} {\[} {[} {\]} {]}] $t]
  return $t
}

proc ::pin3d::strip_tier_suffix {master_name} {
  if {[string match "*_upper" $master_name]} {
    return [string range $master_name 0 end-6]
  }
  if {[string match "*_bottom" $master_name]} {
    return [string range $master_name 0 end-7]
  }
  return $master_name
}

# Deduplicate and normalize mixed 2D/3D LEF/LIB path lists before handing
# them to OpenROAD.
proc ::pin3d::normalize_path_list {paths} {
  set out {}
  set seen [dict create]
  foreach path $paths {
    if {$path eq ""} {
      continue
    }
    if {![file exists $path]} {
      continue
    }
    set norm [file normalize $path]
    if {[dict exists $seen $norm]} {
      continue
    }
    dict set seen $norm 1
    lappend out $norm
  }
  return $out
}

# Small recursive walker used to collect platform LEF/LIB payloads.
proc ::pin3d::collect_files_recursive {root pattern} {
  set out {}
  if {![file exists $root] || ![file isdirectory $root]} {
    return $out
  }
  foreach path [glob -nocomplain -directory $root *] {
    if {[file isdirectory $path]} {
      set out [concat $out [::pin3d::collect_files_recursive $path $pattern]]
    } elseif {[string match $pattern [file tail $path]]} {
      lappend out [file normalize $path]
    }
  }
  return $out
}

# ----------------------------------------------------------------------
# Mixed 2D/3D library view construction
# ----------------------------------------------------------------------

proc ::pin3d::derive_2d_platform_dir {} {
  if {![info exists ::env(PLATFORM)] || $::env(PLATFORM) eq ""} {
    utl::error PIN3D 100 "PLATFORM is not set."
  }
  if {![string match "*_3D" $::env(PLATFORM)]} {
    utl::error PIN3D 101 "PLATFORM '$::env(PLATFORM)' must end with '_3D'."
  }
  set platform_2d [string range $::env(PLATFORM) 0 end-3]
  set platform_root [file dirname [file normalize $::env(PLATFORM_DIR)]]
  set platform_dir_2d [file join $platform_root $platform_2d]
  if {![file isdirectory $platform_dir_2d]} {
    utl::error PIN3D 102 "Derived 2D platform directory not found: $platform_dir_2d"
  }
  return [file normalize $platform_dir_2d]
}

proc ::pin3d::collect_2d_lefs {platform_dir_2d} {
  set lef_root [file join $platform_dir_2d lef]
  set out {}
  foreach lef [::pin3d::collect_files_recursive $lef_root *.lef] {
    set tail [file tail $lef]
    if {[string match "*tech*.lef" $tail]} {
      continue
    }
    if {[string match "*.rect.lef" $tail]} {
      continue
    }
    if {[string match "*.macro.lef" $tail]} {
      set mod_variant [file join [file dirname $lef] [string map [list ".macro.lef" ".macro.mod.lef"] $tail]]
      if {[file exists $mod_variant]} {
        continue
      }
    }
    lappend out $lef
  }
  return [::pin3d::normalize_path_list $out]
}

proc ::pin3d::collect_2d_libs {platform_dir_2d} {
  set lib_root [file join $platform_dir_2d lib]
  return [::pin3d::normalize_path_list [::pin3d::collect_files_recursive $lib_root *.lib]]
}

proc ::pin3d::configure_mixed_library_view {} {
  # The 3D platform carries tier-suffixed stdcells, but the 2D seed design may
  # still reference unsuffixed masters. Load both views so either seed format
  # can be reopened inside one ODB session.
  set platform_dir_2d [::pin3d::derive_2d_platform_dir]
  set lefs_2d [::pin3d::collect_2d_lefs $platform_dir_2d]
  set libs_2d [::pin3d::collect_2d_libs $platform_dir_2d]

  if {![info exists ::env(LEF_FILES)] || $::env(LEF_FILES) eq ""} {
    utl::error PIN3D 103 "LEF_FILES is empty."
  }
  if {![info exists ::env(LIB_FILES)] || $::env(LIB_FILES) eq ""} {
    utl::error PIN3D 104 "LIB_FILES is empty."
  }

  set ::env(LEF_FILES) [::pin3d::normalize_path_list [concat $::env(LEF_FILES) $lefs_2d]]
  set ::env(LIB_FILES) [::pin3d::normalize_path_list [concat $::env(LIB_FILES) $libs_2d]]

  ::pin3d::log "Derived 2D platform: $platform_dir_2d"
  ::pin3d::log "Mixed LEF count=[llength $::env(LEF_FILES)] LIB count=[llength $::env(LIB_FILES)]"
}

# ----------------------------------------------------------------------
# Input parsing
# ----------------------------------------------------------------------

proc ::pin3d::parse_partition_file {path} {
  if {$path eq "" || ![file exists $path]} {
    utl::error PIN3D 105 "partition file not found: $path"
  }
  set fh [open $path r]
  set part_map [dict create]
  while {[gets $fh line] >= 0} {
    set s [string trim $line]
    if {$s eq "" || [string match "#*" $s] || [string match "//*" $s]} {
      continue
    }
    set toks [split $s]
    if {[llength $toks] < 2} {
      continue
    }
    set die_s [lindex $toks end]
    if {$die_s ni {"0" "1"}} {
      continue
    }
    dict set part_map [::pin3d::normalize_name [lindex $toks 0]] $die_s
  }
  close $fh
  if {[dict size $part_map] == 0} {
    utl::error PIN3D 106 "partition file is empty or invalid: $path"
  }
  return $part_map
}

proc ::pin3d::is_power_pin_name {pin_name} {
  expr {[string toupper $pin_name] in {"VDD" "VSS" "VPWR" "VGND" "VPB" "VNB" "VNW"}}
}

# Keep the parsed cell map in a single dict so the later flow can pass one
# object around instead of many parallel arrays.
proc ::pin3d::empty_cell_map {} {
  return [dict create \
    base_to_bottom [dict create] \
    base_to_upper [dict create] \
    base_to_pin_map [dict create] \
    base_to_upper_extra_pins [dict create] \
    base_to_tier_areas [dict create] \
    has_heterogeneous_area_map 0]
}

proc ::pin3d::parse_cell_map {path} {
  if {$path eq ""} {
    ::pin3d::warn "cell map JSON is not set, skip explicit mapping and use suffix fallback."
    return [::pin3d::empty_cell_map]
  }
  if {![file exists $path]} {
    ::pin3d::warn "cell map JSON '$path' not found, skip explicit mapping and use suffix fallback."
    return [::pin3d::empty_cell_map]
  }
  if {[catch {set data [::json_lite::parse_file $path]} err]} {
    ::pin3d::warn "cell map JSON '$path' parse failed, skip explicit mapping and use suffix fallback. error=$err"
    return [::pin3d::empty_cell_map]
  }
  if {![::json_lite::dict_exists_path $data cells]} {
    ::pin3d::warn "cell map JSON '$path' missing 'cells', skip explicit mapping and use suffix fallback."
    return [::pin3d::empty_cell_map]
  }

  set base_to_bottom [dict create]
  set base_to_upper [dict create]
  set base_to_pin_map [dict create]
  set base_to_upper_extra_pins [dict create]
  set base_to_tier_areas [dict create]
  set has_heterogeneous_area_map 0

  set cells [dict get $data cells]
  dict for {cell_key cell_data} $cells {
    set base [::json_lite::dict_get_default $cell_data base $cell_key]
    set bottom [::json_lite::dict_get_default $cell_data bottom [dict create]]
    set upper [::json_lite::dict_get_default $cell_data upper [dict create]]
    set pin_map [::json_lite::dict_get_default $cell_data pin_map [dict create]]

    set bottom_macro [::json_lite::dict_get_default $bottom macro ""]
    set upper_macro [::json_lite::dict_get_default $upper macro ""]
    if {$bottom_macro ne ""} {
      dict set base_to_bottom $base $bottom_macro
    }
    if {$upper_macro ne ""} {
      dict set base_to_upper $base $upper_macro
    }
    if {[dict size $pin_map] > 0} {
      dict set base_to_pin_map $base $pin_map
    }

    set upper_pins [::json_lite::dict_get_default $upper pins {}]
    if {[llength $upper_pins] > 0} {
      set mapped_upper {}
      dict for {old_pin new_pin} $pin_map {
        lappend mapped_upper $new_pin
      }
      set mapped_upper [lsort -unique $mapped_upper]
      set extras {}
      foreach pin $upper_pins {
        if {[lsearch -exact $mapped_upper $pin] >= 0} {
          continue
        }
        if {[::pin3d::is_power_pin_name $pin]} {
          continue
        }
        lappend extras $pin
      }
      if {[llength $extras] > 0} {
        dict set base_to_upper_extra_pins $base $extras
      }
    }

    set bw [::json_lite::try_double [::json_lite::dict_get_default $bottom width ""] ""]
    set bh [::json_lite::try_double [::json_lite::dict_get_default $bottom height ""] ""]
    set uw [::json_lite::try_double [::json_lite::dict_get_default $upper width ""] ""]
    set uh [::json_lite::try_double [::json_lite::dict_get_default $upper height ""] ""]
    if {$bw ne "" && $bh ne "" && $uw ne "" && $uh ne ""} {
      set bottom_area [expr {$bw * $bh}]
      set upper_area [expr {$uw * $uh}]
      dict set base_to_tier_areas $base [list $bottom_area $upper_area]
      if {$bottom_macro ne $upper_macro || abs($bottom_area - $upper_area) > 1.0e-12} {
        set has_heterogeneous_area_map 1
      }
    }
  }

  return [dict create \
    base_to_bottom $base_to_bottom \
    base_to_upper $base_to_upper \
    base_to_pin_map $base_to_pin_map \
    base_to_upper_extra_pins $base_to_upper_extra_pins \
    base_to_tier_areas $base_to_tier_areas \
    has_heterogeneous_area_map $has_heterogeneous_area_map]
}

# ----------------------------------------------------------------------
# ODB inspection and partition orientation
# ----------------------------------------------------------------------

proc ::pin3d::collect_block_context {block} {
  set insts {}
  set norm_to_inst [dict create]
  set norm_to_base [dict create]
  foreach inst [::odb::dbBlock_getInsts $block] {
    lappend insts $inst
    set inst_name [$inst getName]
    set inst_norm [::pin3d::normalize_name $inst_name]
    set master_name [[ $inst getMaster ] getName]
    dict set norm_to_inst $inst_norm $inst
    dict set norm_to_base $inst_norm [::pin3d::strip_tier_suffix $master_name]
  }
  set top_pins [dict create]
  foreach bterm [::odb::dbBlock_getBTerms $block] {
    dict set top_pins [::pin3d::normalize_name [$bterm getName]] 1
  }
  return [dict create \
    insts $insts \
    norm_to_inst $norm_to_inst \
    norm_to_base $norm_to_base \
    top_pins $top_pins]
}

proc ::pin3d::swap_partition_labels {part_map} {
  set swapped [dict create]
  dict for {name die} $part_map {
    if {$die ni {"0" "1"}} {
      dict set swapped $name $die
    } elseif {$die eq "0"} {
      dict set swapped $name 1
    } else {
      dict set swapped $name 0
    }
  }
  return $swapped
}

proc ::pin3d::choose_partition_orientation_by_area {part_map norm_to_base base_to_tier_areas has_heterogeneous_area_map} {
  if {[dict size $part_map] == 0 || !$has_heterogeneous_area_map || [dict size $base_to_tier_areas] == 0} {
    ::pin3d::log "Keep original partition labels: no usable heterogeneous map-based area data."
    return $part_map
  }

  set original_upper_area 0.0
  set original_bottom_area 0.0
  set swapped_upper_area 0.0
  set swapped_bottom_area 0.0
  set mapped_count 0
  set skipped_count 0

  dict for {name die} $part_map {
    if {$die ni {"0" "1"}} {
      incr skipped_count
      continue
    }
    if {![dict exists $norm_to_base $name]} {
      incr skipped_count
      continue
    }
    set base [dict get $norm_to_base $name]
    if {![dict exists $base_to_tier_areas $base]} {
      incr skipped_count
      continue
    }
    lassign [dict get $base_to_tier_areas $base] bottom_area upper_area
    incr mapped_count

    if {$die eq "0"} {
      set original_upper_area [expr {$original_upper_area + $upper_area}]
      set swapped_bottom_area [expr {$swapped_bottom_area + $bottom_area}]
    } else {
      set original_bottom_area [expr {$original_bottom_area + $bottom_area}]
      set swapped_upper_area [expr {$swapped_upper_area + $upper_area}]
    }
  }

  if {$mapped_count == 0} {
    ::pin3d::log "Keep original partition labels: no instances matched usable map-based area data."
    return $part_map
  }

  set original_max_area [expr {($original_upper_area > $original_bottom_area) ? $original_upper_area : $original_bottom_area}]
  set swapped_max_area [expr {($swapped_upper_area > $swapped_bottom_area) ? $swapped_upper_area : $swapped_bottom_area}]
  ::pin3d::log [format "Partition orientation area estimate: mapped=%d skipped=%d; original upper=%.6f bottom=%.6f max=%.6f; swapped upper=%.6f bottom=%.6f max=%.6f" \
    $mapped_count $skipped_count $original_upper_area $original_bottom_area $original_max_area \
    $swapped_upper_area $swapped_bottom_area $swapped_max_area]

  if {$swapped_max_area + 1.0e-12 < $original_max_area} {
    ::pin3d::log "Selected swapped partition orientation: label 0 -> bottom, label 1 -> upper."
    return [::pin3d::swap_partition_labels $part_map]
  }

  ::pin3d::log "Selected original partition orientation: label 0 -> upper, label 1 -> bottom."
  return $part_map
}

# Homogeneous libraries cannot use tier-area estimates, so fall back to the
# Python-compatible "pin-heavier cluster stays on bottom" heuristic.
proc ::pin3d::choose_partition_orientation_by_pins {part_map top_pins} {
  if {[dict size $part_map] == 0 || [dict size $top_pins] == 0} {
    ::pin3d::log "Keep original partition labels: no DEF top-level pins found for homogeneous pin-based orientation."
    return $part_map
  }

  set pin_count_0 0
  set pin_count_1 0
  set skipped_count 0
  dict for {name die} $part_map {
    if {![dict exists $top_pins $name]} {
      continue
    }
    if {$die eq "0"} {
      incr pin_count_0
    } elseif {$die eq "1"} {
      incr pin_count_1
    } else {
      incr skipped_count
    }
  }

  set total_pins [expr {$pin_count_0 + $pin_count_1}]
  if {$total_pins == 0} {
    ::pin3d::log "Keep original partition labels: no partitioned top-level pins matched DEF PINS."
    return $part_map
  }

  ::pin3d::log "Homogeneous pin-based orientation estimate: partition0_pins=$pin_count_0 partition1_pins=$pin_count_1 skipped=$skipped_count"
  if {$pin_count_0 > $pin_count_1} {
    ::pin3d::log "Selected swapped partition orientation: pin-heavier cluster moved to bottom tier."
    return [::pin3d::swap_partition_labels $part_map]
  }
  if {$pin_count_1 > $pin_count_0} {
    ::pin3d::log "Selected original partition orientation: pin-heavier cluster already on bottom tier."
  } else {
    ::pin3d::log "Keep original partition labels: homogeneous pin counts tie."
  }
  return $part_map
}

proc ::pin3d::choose_partition_orientation {part_map cell_map norm_to_base top_pins} {
  set adjusted_part_map [::pin3d::choose_partition_orientation_by_area \
    $part_map \
    $norm_to_base \
    [dict get $cell_map base_to_tier_areas] \
    [dict get $cell_map has_heterogeneous_area_map]]

  if {![dict get $cell_map has_heterogeneous_area_map] || [dict size [dict get $cell_map base_to_tier_areas]] == 0} {
    set adjusted_part_map [::pin3d::choose_partition_orientation_by_pins $adjusted_part_map $top_pins]
  }
  return $adjusted_part_map
}

# ----------------------------------------------------------------------
# Instance remapping and reconnection
# ----------------------------------------------------------------------

proc ::pin3d::target_master_name {base die cell_map stats_var} {
  upvar 1 $stats_var stats
  if {$die eq "0"} {
    set explicit [::json_lite::dict_get_default [dict get $cell_map base_to_upper] $base ""]
    if {$explicit ne ""} {
      return $explicit
    }
    dict incr stats fallback_count
    return "${base}_upper"
  }
  set explicit [::json_lite::dict_get_default [dict get $cell_map base_to_bottom] $base ""]
  if {$explicit ne ""} {
    return $explicit
  }
  dict incr stats fallback_count
  return "${base}_bottom"
}

proc ::pin3d::record_instance_extra_pins {extra_bindings_var inst_name extra_pins connected_targets} {
  upvar 1 $extra_bindings_var extra_bindings
  if {[llength $extra_pins] == 0} {
    return
  }
  set missing {}
  foreach pin $extra_pins {
    if {![dict exists $connected_targets $pin]} {
      lappend missing $pin
    }
  }
  if {[llength $missing] > 0} {
    dict set extra_bindings [::pin3d::normalize_name $inst_name] $missing
  }
}

proc ::pin3d::index_instance_iterms {inst} {
  set by_name [dict create]
  foreach iterm [$inst getITerms] {
    dict set by_name [[$iterm getMTerm] getName] $iterm
  }
  return $by_name
}

proc ::pin3d::lookup_target_master {db target_master_name cache_var} {
  upvar 1 $cache_var cache
  if {![dict exists $cache $target_master_name]} {
    set target_master [::odb::dbDatabase_findMaster $db $target_master_name]
    dict set cache $target_master_name $target_master
  }
  return [dict get $cache $target_master_name]
}

proc ::pin3d::replace_partitioned_instances {block db insts part_map cell_map norm_to_inst} {
  set stats [dict create upper_count 0 bottom_count 0 fallback_count 0 ignored_partition_names 0 total_partition_names [dict size $part_map]]
  set extra_bindings [dict create]
  set base_to_pin_map [dict get $cell_map base_to_pin_map]
  set base_to_upper_extra_pins [dict get $cell_map base_to_upper_extra_pins]
  set target_master_cache [dict create]

  set ignored 0
  dict for {name die} $part_map {
    if {![dict exists $norm_to_inst $name]} {
      incr ignored
    }
  }
  dict set stats ignored_partition_names $ignored

  dict set stats total_instances [llength $insts]
  dict set stats replaced_instances 0

  foreach inst $insts {
    set inst_name [$inst getName]
    set inst_norm [::pin3d::normalize_name $inst_name]
    if {![dict exists $part_map $inst_norm]} {
      continue
    }
    set die [dict get $part_map $inst_norm]
    if {$die ni {"0" "1"}} {
      continue
    }

    set old_master [$inst getMaster]
    set old_master_name [$old_master getName]
    set base [::pin3d::strip_tier_suffix $old_master_name]
    set target_master_name [::pin3d::target_master_name $base $die $cell_map stats]
    set target_master [::pin3d::lookup_target_master $db $target_master_name target_master_cache]
    if {$target_master eq "" || $target_master eq "NULL"} {
      utl::error PIN3D 109 "Target master '$target_master_name' not found for instance '$inst_name'."
    }

    set pin_to_net [dict create]
    foreach iterm [$inst getITerms] {
      set net [$iterm getNet]
      if {$net eq "" || $net eq "NULL"} {
        continue
      }
      set pin_name [[$iterm getMTerm] getName]
      dict set pin_to_net $pin_name $net
    }

    set loc [$inst getLocation]
    set orient [$inst getOrient]
    set placement_status [$inst getPlacementStatus]
    set source_type [::odb::dbInst_getSourceType $inst]
    set region [::odb::dbInst_getRegion $inst]
    set group [::odb::dbInst_getGroup $inst]

    variable tmp_inst_idx
    incr tmp_inst_idx
    set tmp_name [format "__pin3d_tmp_%d__" $tmp_inst_idx]
    set new_inst [::odb::dbInst_create $block $target_master $tmp_name]
    if {$new_inst eq "" || $new_inst eq "NULL"} {
      utl::error PIN3D 110 "Failed to create replacement instance for '$inst_name'."
    }

    if {[llength $loc] == 2} {
      ::odb::dbInst_setLocation $new_inst [lindex $loc 0] [lindex $loc 1]
    }
    catch {::odb::dbInst_setOrient $new_inst $orient}
    catch {::odb::dbInst_setPlacementStatus $new_inst $placement_status}
    catch {::odb::dbInst_setSourceType $new_inst $source_type}
    if {$region ne "" && $region ne "NULL"} {
      catch {::odb::dbRegion_addInst $region $new_inst}
    }
    if {$group ne "" && $group ne "NULL"} {
      catch {::odb::dbGroup_addInst $group $new_inst}
    }

    set connected_targets [dict create]
    set pin_map [::json_lite::dict_get_default $base_to_pin_map $base [dict create]]
    set extra_pins [::json_lite::dict_get_default $base_to_upper_extra_pins $base {}]
    set new_iterms [::pin3d::index_instance_iterms $new_inst]
    dict for {old_pin net} $pin_to_net {
      if {$die eq "0"} {
        set new_pin [::json_lite::dict_get_default $pin_map $old_pin $old_pin]
      } else {
        set new_pin $old_pin
      }
      if {[dict exists $connected_targets $new_pin]} {
        utl::error PIN3D 111 "Duplicate target pin '$new_pin' while reconnecting '$inst_name'."
      }
      if {![dict exists $new_iterms $new_pin]} {
        utl::error PIN3D 112 "Target pin '$new_pin' not found on master '$target_master_name' for instance '$inst_name'."
      }
      set new_iterm [dict get $new_iterms $new_pin]
      $new_iterm connect $net
      dict set connected_targets $new_pin 1
    }

    if {$die eq "0"} {
      ::pin3d::record_instance_extra_pins extra_bindings $inst_name $extra_pins $connected_targets
      dict incr stats upper_count
    } else {
      dict incr stats bottom_count
    }

    ::odb::dbInst_destroy $inst
    $new_inst rename $inst_name
    dict incr stats replaced_instances
  }

  dict set stats extra_pin_injection_count [dict size $extra_bindings]
  return [dict create stats $stats extra_bindings $extra_bindings]
}

# ----------------------------------------------------------------------
# Verilog post-processing
# ----------------------------------------------------------------------

proc ::pin3d::split_verilog_statements {text} {
  set spans {}
  set depth 0
  set in_str 0
  set esc 0
  set start 0
  set n [string length $text]
  for {set i 0} {$i < $n} {incr i} {
    set ch [string index $text $i]
    if {$in_str} {
      if {$esc} {
        set esc 0
      } elseif {$ch eq "\\"} {
        set esc 1
      } elseif {$ch eq "\""} {
        set in_str 0
      }
      continue
    }
    switch -- $ch {
      "\"" { set in_str 1 }
      "("  { incr depth }
      ")"  { if {$depth > 0} { incr depth -1 } }
      ";"  {
        if {$depth == 0} {
          lappend spans [list $start [expr {$i + 1}]]
          set start [expr {$i + 1}]
        }
      }
    }
  }
  if {$start < $n} {
    lappend spans [list $start $n]
  }
  return $spans
}

proc ::pin3d::append_extra_ports_instance {stmt extra_pins} {
  if {[llength $extra_pins] == 0} {
    return $stmt
  }

  set existing {}
  set search_idx 0
  while {[regexp -indices -start $search_idx {\.\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\(} $stmt match_idx pin_idx]} {
    lappend existing [string range $stmt [lindex $pin_idx 0] [lindex $pin_idx 1]]
    set search_idx [expr {[lindex $match_idx 1] + 1}]
  }

  set missing {}
  foreach pin $extra_pins {
    if {[lsearch -exact $existing $pin] < 0} {
      lappend missing $pin
    }
  }
  if {[llength $missing] == 0} {
    return $stmt
  }

  set pos [string last ");" $stmt]
  if {$pos < 0} {
    return $stmt
  }

  set prefix [string range $stmt 0 [expr {$pos - 1}]]
  set line_start [expr {[string last "\n" $prefix] + 1}]
  set indent "  "
  if {$line_start >= 0 && $line_start < [string length $prefix]} {
    set tail [string range $prefix $line_start end]
    if {[regexp {^(\s*)} $tail -> spaces]} {
      set indent $spaces
    }
  }

  set insert_text ""
  foreach pin $missing {
    append insert_text ",\n${indent}.${pin}(1'b0)"
  }
  return "[string range $stmt 0 [expr {$pos - 1}]]$insert_text[string range $stmt $pos end]"
}

proc ::pin3d::patch_verilog_extra_pins {path extra_bindings} {
  if {[dict size $extra_bindings] == 0} {
    return 0
  }
  set fh [open $path r]
  set text [read $fh]
  close $fh

  set out ""
  set last 0
  set patched 0
  foreach span [::pin3d::split_verilog_statements $text] {
    lassign $span start end
    if {$start > $last} {
      append out [string range $text $last [expr {$start - 1}]]
    }
    set stmt [string range $text $start [expr {$end - 1}]]
    set last $end

    if {[regexp -expanded -lineanchor {(?xs)
        ^\s*
        \S+
        \s+
        (?:\#\s*\([^;]*\)\s+)?
        ((?:\\\S+)|(?:[A-Za-z_][A-Za-z0-9_$]*))
        \s*\(
      } $stmt -> inst_tok]} {
      set inst_norm [::pin3d::normalize_name $inst_tok]
      if {[dict exists $extra_bindings $inst_norm]} {
        set stmt2 [::pin3d::append_extra_ports_instance $stmt [dict get $extra_bindings $inst_norm]]
        if {$stmt2 ne $stmt} {
          incr patched
        }
        append out $stmt2
        continue
      }
    }
    append out $stmt
  }
  if {$last < [string length $text]} {
    append out [string range $text $last end]
  }

  set fh [open $path w]
  puts -nonewline $fh $out
  close $fh
  return $patched
}

# When Yosys preserves hierarchy, OpenROAD can reopen the placed seed more
# reliably from DEF than from the escaped instance names in Verilog.
proc ::pin3d::netlist_has_hier_instance_names {path} {
  if {![file exists $path]} {
    return 0
  }
  set fh [open $path r]
  set found 0
  while {[gets $fh line] >= 0} {
    if {[regexp {^\s*\S+\s+\\\S*/\S*\s*\(} $line]} {
      set found 1
      break
    }
  }
  close $fh
  return $found
}

proc ::pin3d::resolve_run_inputs {} {
  foreach {env_name err_code} {RESULTS_DIR 113 PLATFORM_DIR 114 DESIGN_NAME 115} {
    if {![info exists ::env($env_name)] || $::env($env_name) eq ""} {
      utl::error PIN3D $err_code "$env_name is not set."
    }
  }

  return [dict create \
    partition_path [file join $::env(RESULTS_DIR) partition.txt] \
    cell_map_path [file join $::env(PLATFORM_DIR) map.json] \
    def_in [file join $::env(RESULTS_DIR) 2_2_floorplan_io.def] \
    v_in [file join $::env(RESULTS_DIR) 2_2_floorplan_io.v] \
    sdc_in [file join $::env(RESULTS_DIR) 1_synth.sdc] \
    v_out [file join $::env(RESULTS_DIR) "${::env(DESIGN_NAME)}_3D.fp.v"] \
    def_out [file join $::env(RESULTS_DIR) "${::env(DESIGN_NAME)}_3D.fp.def"]]
}

proc ::pin3d::load_seed_design {run_inputs} {
  set def_in [dict get $run_inputs def_in]
  set v_in [dict get $run_inputs v_in]
  set sdc_in [dict get $run_inputs sdc_in]

  if {[file exists $def_in] && [::pin3d::netlist_has_hier_instance_names $v_in]} {
    ::pin3d::log "Loading placed 2D DEF snapshot: $def_in (detected hierarchical instance names in $v_in)"
    load_design $def_in $sdc_in "Generate 3D views"
    return
  }

  if {[file exists $def_in]} {
    ::pin3d::log "Using netlist load: $v_in (no hierarchical instance names detected)"
  } else {
    ::pin3d::log "Placed 2D DEF snapshot not found; falling back to netlist load: $v_in"
  }
  load_design $v_in $sdc_in "Generate 3D views"
}

proc ::pin3d::write_outputs {run_inputs extra_bindings stats_var} {
  upvar 1 $stats_var stats

  set def_out [dict get $run_inputs def_out]
  set v_out [dict get $run_inputs v_out]
  write_def $def_out
  write_verilog $v_out
  dict set stats extra_pin_injection_count [::pin3d::patch_verilog_extra_pins $v_out $extra_bindings]
}

# ----------------------------------------------------------------------
# Main entry
# ----------------------------------------------------------------------

proc ::pin3d::run {} {
  set run_inputs [::pin3d::resolve_run_inputs]
  set part_map [::pin3d::parse_partition_file [dict get $run_inputs partition_path]]
  set cell_map [::pin3d::parse_cell_map [dict get $run_inputs cell_map_path]]
  ::pin3d::configure_mixed_library_view
  ::pin3d::load_seed_design $run_inputs

  set db [ord::get_db]
  set block [ord::get_db_block]
  if {$db eq "NULL" || $block eq "NULL"} {
    utl::error PIN3D 116 "OpenROAD database is not initialized."
  }

  set block_context [::pin3d::collect_block_context $block]
  set insts [dict get $block_context insts]
  set norm_to_inst [dict get $block_context norm_to_inst]
  set norm_to_base [dict get $block_context norm_to_base]
  set top_pins [dict get $block_context top_pins]

  set adjusted_part_map [::pin3d::choose_partition_orientation $part_map $cell_map $norm_to_base $top_pins]
  set replace_result [::pin3d::replace_partitioned_instances $block $db $insts $adjusted_part_map $cell_map $norm_to_inst]
  set stats [dict get $replace_result stats]
  set extra_bindings [dict get $replace_result extra_bindings]
  ::pin3d::write_outputs $run_inputs $extra_bindings stats

  ::pin3d::log [format "Summary: total_instances=%d replaced=%d upper=%d bottom=%d fallback=%d extra_pin_injections=%d ignored_partition_names=%d" \
    [dict get $stats total_instances] \
    [dict get $stats replaced_instances] \
    [dict get $stats upper_count] \
    [dict get $stats bottom_count] \
    [dict get $stats fallback_count] \
    [dict get $stats extra_pin_injection_count] \
    [dict get $stats ignored_partition_names]]
}

if {![info exists ::env(PIN3D_NO_AUTORUN)] || $::env(PIN3D_NO_AUTORUN) eq "" || $::env(PIN3D_NO_AUTORUN) eq "0"} {
  ::pin3d::run
  exit
}
