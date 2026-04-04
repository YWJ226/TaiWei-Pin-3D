namespace eval ::pin3d_pdn_macro {
  variable orient_groups [list \
    [list R0 R180 MX MY] \
    [list R90 R270 MXR90 MYR90]]
}

proc pin3d_pdn_layer_exists {layer_name} {
  if {$layer_name eq ""} {
    return 0
  }
  set tech [ord::get_db_tech]
  set layer [::odb::dbTech_findLayer $tech $layer_name]
  expr {$layer ne "NULL" && $layer ne ""}
}

proc pin3d_pdn_macro_tier_of_inst {inst} {
  set master_name [[$inst getMaster] getName]
  set inst_name [$inst getName]
  if {[string match "*_upper" $master_name] || [string match "*_upper" $inst_name]} {
    return "upper"
  }
  if {[string match "*_bottom" $master_name] || [string match "*_lower" $master_name] \
      || [string match "*_bottom" $inst_name] || [string match "*_lower" $inst_name]} {
    return "bottom"
  }
  return ""
}

proc pin3d_pdn_macro_halo {} {
  set default_halo [list 2.0 2.0 2.0 2.0]
  if {![info exists ::env(MACRO_PLACE_HALO)] || $::env(MACRO_PLACE_HALO) eq ""} {
    return $default_halo
  }
  set values $::env(MACRO_PLACE_HALO)
  switch -- [llength $values] {
    1 {
      set h [lindex $values 0]
      return [list $h $h $h $h]
    }
    2 {
      set hx [lindex $values 0]
      set hy [lindex $values 1]
      return [list $hx $hy $hx $hy]
    }
    4 {
      return $values
    }
    default {
      puts "WARN: invalid MACRO_PLACE_HALO '$::env(MACRO_PLACE_HALO)'; using default $default_halo"
      return $default_halo
    }
  }
}

proc pin3d_pdn_macro_cells_for_tier {tier} {
  set block [ord::get_db_block]
  set cell_dict [dict create]
  foreach inst [$block getInsts] {
    set master [$inst getMaster]
    if {[$master getType] ne "BLOCK"} {
      continue
    }
    if {[pin3d_pdn_macro_tier_of_inst $inst] ne $tier} {
      continue
    }
    dict set cell_dict [$master getName] 1
  }
  return [lsort -dictionary [dict keys $cell_dict]]
}

proc pin3d_pdn_macro_insts_for_tier {tier} {
  set block [ord::get_db_block]
  set inst_names [list]
  foreach inst [$block getInsts] {
    set master [$inst getMaster]
    if {[$master getType] ne "BLOCK"} {
      continue
    }
    if {[pin3d_pdn_macro_tier_of_inst $inst] ne $tier} {
      continue
    }
    lappend inst_names [$inst getName]
  }
  return [lsort -dictionary $inst_names]
}

proc pin3d_pdn_regex_escape {text} {
  set escaped $text
  regsub -all -- {([][(){}.+*?^$\\|])} $escaped {\\\1} escaped
  return $escaped
}

proc pin3d_add_macro_global_connections {tier power_net ground_net} {
  set inst_names [pin3d_pdn_macro_insts_for_tier $tier]
  if {[llength $inst_names] == 0} {
    return 0
  }
  foreach inst_name $inst_names {
    set pattern [format "^%s$" [pin3d_pdn_regex_escape $inst_name]]
    add_global_connection -net $power_net -inst_pattern $pattern -pin_pattern {^VDD$} -power
    add_global_connection -net $power_net -inst_pattern $pattern -pin_pattern {^VDDPE$}
    add_global_connection -net $power_net -inst_pattern $pattern -pin_pattern {^VDDCE$}
    add_global_connection -net $ground_net -inst_pattern $pattern -pin_pattern {^VSS$} -ground
    add_global_connection -net $ground_net -inst_pattern $pattern -pin_pattern {^VSSE$}
  }
  puts "INFO: Added explicit macro global connections for [llength $inst_names] $tier macro instances."
  return [llength $inst_names]
}

proc pin3d_add_macro_grids {args} {
  array set opt {
    -tier ""
    -grid_prefix ""
    -voltage_domain Core
    -nets {}
    -grid_mode pg_pins
    -macro_layers {}
    -stripe_widths {}
    -stripe_pitches {}
    -stripe_offsets {}
    -stripe_spacings {}
    -connect_layers {}
  }

  if {[expr {[llength $args] % 2}] != 0} {
    error "pin3d_add_macro_grids: expected key/value arguments"
  }
  foreach {key value} $args {
    if {![info exists opt($key)]} {
      error "pin3d_add_macro_grids: unknown option '$key'"
    }
    set opt($key) $value
  }

  if {$opt(-tier) ni {upper bottom}} {
    error "pin3d_add_macro_grids: -tier must be upper or bottom"
  }
  if {$opt(-grid_prefix) eq ""} {
    error "pin3d_add_macro_grids: -grid_prefix is required"
  }

  set macro_cells [pin3d_pdn_macro_cells_for_tier $opt(-tier)]
  if {[llength $macro_cells] == 0} {
    puts "INFO: No $opt(-tier) macros found for PDN macro grids."
    return {}
  }

  set required_layers [list]
  foreach layer $opt(-macro_layers) {
    if {$layer ne ""} {
      lappend required_layers $layer
    }
  }
  foreach pair $opt(-connect_layers) {
    foreach layer $pair {
      if {$layer ne ""} {
        lappend required_layers $layer
      }
    }
  }
  foreach layer [lsort -unique $required_layers] {
    if {![pin3d_pdn_layer_exists $layer]} {
      error "pin3d_add_macro_grids: required layer '$layer' does not exist"
    }
  }

  set halo [pin3d_pdn_macro_halo]
  set grid_names [list]
  set idx 1
  foreach orient_group $::pin3d_pdn_macro::orient_groups {
    set grid_name [format "%s_macro_grid_%d" $opt(-grid_prefix) $idx]
    set define_cmd [list \
      define_pdn_grid \
      -macro \
      -name $grid_name \
      -cells $macro_cells \
      -orient $orient_group \
      -halo $halo \
      -starts_with POWER \
      -voltage_domains [list $opt(-voltage_domain)]]
    if {$opt(-grid_mode) eq "pg_pins"} {
      lappend define_cmd -grid_over_pg_pins
    } elseif {$opt(-grid_mode) eq "boundary"} {
      lappend define_cmd -grid_over_boundary
    } else {
      error "pin3d_add_macro_grids: -grid_mode must be boundary or pg_pins"
    }
    uplevel #0 $define_cmd

    set layer_count [llength $opt(-macro_layers)]
    if {[llength $opt(-stripe_widths)] != $layer_count \
        || [llength $opt(-stripe_pitches)] != $layer_count \
        || [llength $opt(-stripe_offsets)] != $layer_count} {
      error "pin3d_add_macro_grids: stripe layer/width/pitch/offset lists must have the same length"
    }
    if {[llength $opt(-stripe_spacings)] > 0 && [llength $opt(-stripe_spacings)] != $layer_count} {
      error "pin3d_add_macro_grids: stripe spacings must be empty or match -macro_layers length"
    }

    for {set i 0} {$i < $layer_count} {incr i} {
      set stripe_cmd [list \
        add_pdn_stripe \
        -grid $grid_name \
        -layer [lindex $opt(-macro_layers) $i] \
        -width [lindex $opt(-stripe_widths) $i] \
        -pitch [lindex $opt(-stripe_pitches) $i] \
        -offset [lindex $opt(-stripe_offsets) $i]]
      if {[llength $opt(-stripe_spacings)] > 0} {
        set spacing [lindex $opt(-stripe_spacings) $i]
        if {$spacing ne ""} {
          lappend stripe_cmd -spacing $spacing
        }
      }
      if {[llength $opt(-nets)] > 0} {
        lappend stripe_cmd -nets $opt(-nets)
      }
      uplevel #0 $stripe_cmd
    }

    foreach connect_pair $opt(-connect_layers) {
      uplevel #0 [list add_pdn_connect -grid $grid_name -layers $connect_pair]
    }
    lappend grid_names $grid_name
    incr idx
  }

  puts "INFO: Added [llength $grid_names] macro PDN grids for $opt(-tier) tier cells: [join $macro_cells { }]"
  return $grid_names
}
