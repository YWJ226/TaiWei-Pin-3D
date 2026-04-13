proc _resolve_flow_path {path} {
  if {$path eq ""} {
    return ""
  }
  if {[file pathtype $path] eq "absolute"} {
    return [file normalize $path]
  }
  if {[file exists $path]} {
    return [file normalize $path]
  }
  if {[file dirname $path] ne "."} {
    return [file normalize $path]
  }
  return [file normalize [file join $::env(RESULTS_DIR) $path]]
}

proc load_design {design_file sdc_file msg} {
  set design_file [_resolve_flow_path $design_file]
  set sdc_file [_resolve_flow_path $sdc_file]
  if {![info exists standalone] || $standalone} {
    # Read liberty files
    puts "Reading liberty files..."
    source $::env(OPENROAD_SCRIPTS_DIR)/read_liberty.tcl
    # Read design files
    set ext [file extension $design_file]
    if {$ext == ".def"} {
      if {[info exists ::env(LEF_FILES)]} {
        foreach lef $::env(LEF_FILES) {
          read_lef $lef
        }
      }
      # read_verilog $::env(RESULTS_DIR)/$design_file
      # puts "Linking design $::env(DESIGN_NAME)..."
      # link_design $::env(DESIGN_NAME)
      read_def $design_file
    } elseif {$ext == ".odb"} {
      read_db $design_file
    } elseif {$ext == ".v"} {
      if {[info exists ::env(LEF_FILES)]} {
        foreach lef $::env(LEF_FILES) {
          read_lef $lef
        }
      }
      read_verilog $design_file
      puts "Linking design $::env(DESIGN_NAME)..."
      link_design $::env(DESIGN_NAME)
      # set def_file [file rootname $design_file].def
      # if {[file exists $def_file]} {
      #   read_def -floorplan_initialize $def_file
      # }
    } else {
      error "Unrecognized input file $design_file"
    }

    # Read SDC file
    
    read_sdc $sdc_file

    if [file exists $::env(PLATFORM_DIR)/derate.tcl] {
      source $::env(PLATFORM_DIR)/derate.tcl
    }

    source $::env(SET_RC_TCL)
  } else {
    puts $msg
  }
}

proc _get {name {def ""}} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $def
}
