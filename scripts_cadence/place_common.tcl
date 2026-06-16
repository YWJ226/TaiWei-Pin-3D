# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# place_common.tcl — Stable pre-GR/pre-legal setup for Innovus placement
# Dependencies: utils.tcl / lib_setup.tcl / design_setup.tcl / mmmc_setup.tcl must be sourced.
# Environment Variables (Optional):
#   MAX_ROUTING_LAYER / MIN_ROUTING_LAYER : Constrain routing layers
# ==========================================
# Ensure namespace exists
if {![namespace exists pc]} {
  namespace eval pc {
    namespace export common_setup setup_basic run_global_place_step run_place run_place_step run_loop_opt_step repair_tie_cells
  }
}

proc pc::_env_or {name default} {
  if {[info exists ::env($name)]} { return $::env($name) }
  return $default
}

proc pc::_env_flag {name default} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    return $default
  }
  set value [string tolower [string trim $::env($name)]]
  switch -- $value {
    1 - on - true - yes - enabled { return 1 }
    0 - off - false - no - disabled { return 0 }
    default { return $default }
  }
}

proc pc::_tie_cell_from_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    return ""
  }
  return [lindex $::env($name) 0]
}

proc pc::_valid_db_ptr {ptr} {
  expr {$ptr ne "" && $ptr ne "0x0"}
}

proc pc::_db_net_exists {net_name} {
  if {$net_name eq ""} {
    return 0
  }

  foreach root {top.nets top.pgNets} {
    set net_ptrs {}
    if {[catch { set net_ptrs [dbGet -e $root] }]} {
      continue
    }
    foreach net_ptr $net_ptrs {
      if {![pc::_valid_db_ptr $net_ptr]} {
        continue
      }
      set name ""
      catch { set name [dbGet $net_ptr.name] }
      if {$name eq $net_name} {
        return 1
      }
    }
  }

  return 0
}

proc pc::_inst_term_pin_name {inst_term} {
  set full_name ""
  catch { set full_name [dbGet $inst_term.name] }
  if {$full_name eq "" || $full_name eq "0x0"} {
    return ""
  }
  set full_name [string trim $full_name "{}"]
  set slash_idx [string last "/" $full_name]
  if {$slash_idx < 0} {
    return [string trim $full_name "{}"]
  }
  return [string trim [string range $full_name [expr {$slash_idx + 1}] end] "{}"]
}

proc pc::_inst_matches_active_tier {inst_ptr} {
  set tier [pc::_env_or PIN3D_ACTIVE_TIER ""]
  if {$tier eq "" || $tier eq "flat"} {
    return 1
  }

  set ref_name ""
  set inst_name ""
  catch { set ref_name [dbGet $inst_ptr.cell.name] }
  catch { set inst_name [dbGet $inst_ptr.name] }

  switch -- $tier {
    upper {
      expr {[string match "*_upper" $ref_name] || [string match "*_upper" $inst_name]}
    }
    bottom {
      expr {[string match "*_bottom" $ref_name] || [string match "*_bottom" $inst_name]}
    }
    default {
      return 1
    }
  }
}

proc pc::_active_tier_cell_pin_filter {} {
  set tier [pc::_env_or PIN3D_ACTIVE_TIER ""]
  if {$tier eq "" || $tier eq "flat"} {
    return {}
  }

  set cell_pins {}
  foreach inst_ptr [dbGet -e top.insts] {
    if {![pc::_inst_matches_active_tier $inst_ptr]} {
      continue
    }

    set ref_name ""
    catch { set ref_name [dbGet $inst_ptr.cell.name] }
    if {$ref_name eq ""} {
      continue
    }

    foreach inst_term [dbGet -e $inst_ptr.instTerms] {
      if {![dbGet $inst_term.isInput]} {
        continue
      }

      set pin_name [pc::_inst_term_pin_name $inst_term]
      if {$pin_name eq ""} {
        continue
      }
      lappend cell_pins "${ref_name}:${pin_name}"
    }
  }

  return [lsort -unique $cell_pins]
}

proc pc::_tie_cell_instance_names {tie_cells} {
  set inst_names {}
  set inst_ptrs {}
  if {[catch { set inst_ptrs [dbGet -e top.insts] }]} {
    return {}
  }

  foreach inst_ptr $inst_ptrs {
    if {![pc::_valid_db_ptr $inst_ptr]} {
      continue
    }

    set ref_name ""
    catch { set ref_name [dbGet $inst_ptr.cell.name] }
    if {[lsearch -exact $tie_cells $ref_name] < 0} {
      continue
    }

    set inst_name ""
    catch { set inst_name [dbGet $inst_ptr.name] }
    if {$inst_name eq "" || $inst_name eq "0x0"} {
      continue
    }
    lappend inst_names $inst_name
  }

  return [lsort -unique $inst_names]
}

proc pc::_connect_tie_cell_pg {tie_cells {stage "tie_hilo"}} {
  set pwr_net [pc::_env_or PIN3D_ACTIVE_PWR_NET VDD]
  set gnd_net [pc::_env_or PIN3D_ACTIVE_GND_NET VSS]
  set inst_names [pc::_tie_cell_instance_names $tie_cells]

  if {[llength $inst_names] == 0} {
    puts "INFO\[pc\]: skip tie PG reconnect stage=$stage because no tie-cell instances were found"
    return
  }

  set missing_nets {}
  if {![pc::_db_net_exists $pwr_net]} {
    lappend missing_nets $pwr_net
  }
  if {![pc::_db_net_exists $gnd_net]} {
    lappend missing_nets $gnd_net
  }
  if {[llength $missing_nets] > 0} {
    puts "WARN\[pc\]: skip tie PG reconnect stage=$stage because PG nets are not in design: [join $missing_nets {, }]"
    return
  }

  puts "INFO\[pc\]: reconnect tie PG stage=$stage tie_instances=[llength $inst_names] pwr=$pwr_net gnd=$gnd_net"
  foreach inst $inst_names {
    globalNetConnect $pwr_net -type pgpin -pin VDD -inst $inst -override
    globalNetConnect $gnd_net -type pgpin -pin VSS -inst $inst -override
    globalNetConnect $pwr_net -type tiehi -inst $inst -override
    globalNetConnect $gnd_net -type tielo -inst $inst -override
  }
}

proc pc::repair_tie_cells {{stage "tie_hilo"}} {
  if {![pc::_env_flag CADENCE_ENABLE_TIE_HILO 1]} {
    puts "INFO\[pc\]: skip addTieHiLo stage=$stage because CADENCE_ENABLE_TIE_HILO=off"
    return
  }

  set tiehi_cell [pc::_tie_cell_from_env TIEHI_CELL_AND_PORT]
  set tielo_cell [pc::_tie_cell_from_env TIELO_CELL_AND_PORT]
  if {$tiehi_cell eq "" || $tielo_cell eq ""} {
    puts "WARN\[pc\]: skip addTieHiLo stage=$stage because TIEHI/TIELO_CELL_AND_PORT is not configured"
    return
  }

  set tier [pc::_env_or PIN3D_ACTIVE_TIER flat]
  set prefix [pc::_env_or CADENCE_TIE_HILO_PREFIX "PIN3D_${tier}_tie_"]
  set pwr_net [pc::_env_or PIN3D_ACTIVE_PWR_NET VDD]
  set gnd_net [pc::_env_or PIN3D_ACTIVE_GND_NET VSS]
  set cell_pin_filter [pc::_active_tier_cell_pin_filter]

  if {$tier ne "flat" && [llength $cell_pin_filter] == 0} {
    puts "WARN\[pc\]: skip addTieHiLo stage=$stage tier=$tier because no active-tier input cell pins were found"
    return
  }

  set mode_args [list \
    -cell [list [list $tiehi_cell $tielo_cell]] \
    -honorDontUse false \
    -honorDontTouch false \
    -prefix $prefix]
  set max_fanout [pc::_env_or CADENCE_TIE_HILO_MAX_FANOUT ""]
  set max_distance [pc::_env_or CADENCE_TIE_HILO_MAX_DISTANCE ""]
  if {$max_fanout ne ""} {
    lappend mode_args -maxFanout $max_fanout
  }
  if {$max_distance ne ""} {
    lappend mode_args -maxDistance $max_distance
  }

  set add_args [list \
    -cell [list $tiehi_cell $tielo_cell] \
    -keepExisting true \
    -prefix $prefix]
  if {[llength $cell_pin_filter] > 0} {
    lappend add_args -cellPin [join $cell_pin_filter " "]
  }

  puts "INFO\[pc\]: addTieHiLo stage=$stage tier=$tier tiehi=$tiehi_cell tielo=$tielo_cell pwr=$pwr_net gnd=$gnd_net cellPin_count=[llength $cell_pin_filter]"
  setTieHiLoMode {*}$mode_args
  addTieHiLo {*}$add_args
  pc::_connect_tie_cell_pg [list $tiehi_cell $tielo_cell] $stage
}

proc pc::setup_basic {} {
  # --- Routing Layer Constraints (if set) ---
  if {[info exists ::env(MAX_ROUTING_LAYER)]} { setDesignMode -topRoutingLayer    $::env(MAX_ROUTING_LAYER) } 
  if {[info exists ::env(MIN_ROUTING_LAYER)]} { setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER) } 

  # --- Legalization and Filler ---
  setPlaceMode -place_detail_legalization_inst_gap 1
  setFillerMode -fitGap true
}

proc pc::run_global_place_step {{prefix "place"}} {
  puts "INFO\[pc\]: place_design, stage=$prefix"
  place_design
  pc::repair_tie_cells $prefix
  catch { checkPlace }
}

# Single-step placement/optimization stage.
proc pc::run_place_step {{prefix "prects"}} {
  puts "INFO\[pc\]: place_opt_design (integrated preCTS opt), stage=$prefix"
  # Report directory/prefix might be defined in your design script; provide a compatible fallback
  set reports_dir [expr {[info exists ::REPORTS_DIR] ? $::REPORTS_DIR : "./reports"}]
  file mkdir $reports_dir
  catch { place_opt_design -out_dir $reports_dir -prefix $prefix } msg
  if {[info exists msg] && $msg ne ""} { puts "INFO\[pc\]: $msg" }
  pc::repair_tie_cells $prefix
  catch { checkPlace }
}

# Outer-loop incremental preCTS optimization stage.
proc pc::run_loop_opt_step {{prefix "loop_prects"}} {
  puts "INFO\[pc\]: loop incremental preCTS optimization, stage=$prefix"
  set reports_dir [expr {[info exists ::REPORTS_DIR] ? $::REPORTS_DIR : "./reports"}]
  file mkdir $reports_dir
  catch { optDesign -preCTS -incr -outDir $reports_dir -prefix $prefix } msg
  if {[info exists msg] && $msg ne ""} { puts "INFO\[pc\]: $msg" }
  pc::repair_tie_cells $prefix
  catch { checkPlace }
}

# Top-level placement entry point.
proc pc::run_place {} {
  pc::run_place_step prects
}
