set pin3d_scripts_dir [file dirname [file normalize [info script]]]
set ::env(OPENROAD_SCRIPTS_DIR) $pin3d_scripts_dir

if {![info exists ::env(HANDOFF_TCL)] || $::env(HANDOFF_TCL) eq ""} {
  puts stderr "ERROR: HANDOFF_TCL is not set."
  exit 1
}

proc pin3d_normalize_optional {path} {
  if {$path eq ""} {
    return ""
  }
  return [file normalize $path]
}

proc pin3d_dict_get {record key {default ""}} {
  if {[dict exists $record $key]} {
    return [dict get $record $key]
  }
  return $default
}

proc pin3d_select_design_input {record} {
  set view "auto"
  if {[info exists ::env(HANDOFF_VIEW)] && $::env(HANDOFF_VIEW) ne ""} {
    set view [string tolower $::env(HANDOFF_VIEW)]
  }

  set ordered_candidates {}
  switch -- $view {
    in {
      set ordered_candidates [list \
        [pin3d_dict_get $record odb_in] \
        [pin3d_dict_get $record def_in] \
        [pin3d_dict_get $record odb_out] \
        [pin3d_dict_get $record def_out]]
    }
    out {
      set ordered_candidates [list \
        [pin3d_dict_get $record odb_out] \
        [pin3d_dict_get $record def_out] \
        [pin3d_dict_get $record odb_in] \
        [pin3d_dict_get $record def_in]]
    }
    default {
      set ordered_candidates [list \
        [pin3d_dict_get $record odb_out] \
        [pin3d_dict_get $record def_out] \
        [pin3d_dict_get $record odb_in] \
        [pin3d_dict_get $record def_in]]
    }
  }

  foreach candidate $ordered_candidates {
    if {$candidate eq ""} {
      continue
    }
    set normalized [pin3d_normalize_optional $candidate]
    if {[file exists $normalized]} {
      return $normalized
    }
  }

  return ""
}

proc pin3d_select_sdc_input {record} {
  set view "auto"
  if {[info exists ::env(HANDOFF_VIEW)] && $::env(HANDOFF_VIEW) ne ""} {
    set view [string tolower $::env(HANDOFF_VIEW)]
  }

  set ordered_candidates {}
  switch -- $view {
    in {
      set ordered_candidates [list \
        [pin3d_dict_get $record sdc_in] \
        [pin3d_dict_get $record sdc_out]]
    }
    out {
      set ordered_candidates [list \
        [pin3d_dict_get $record sdc_out] \
        [pin3d_dict_get $record sdc_in]]
    }
    default {
      set ordered_candidates [list \
        [pin3d_dict_get $record sdc_out] \
        [pin3d_dict_get $record sdc_in]]
    }
  }

  foreach candidate $ordered_candidates {
    if {$candidate eq ""} {
      continue
    }
    set normalized [pin3d_normalize_optional $candidate]
    if {[file exists $normalized]} {
      return $normalized
    }
  }

  return ""
}

proc pin3d_read_lefs {} {
  if {![info exists ::env(LEF_FILES)] || [llength $::env(LEF_FILES)] == 0} {
    puts stderr "ERROR: LEF_FILES is not set for GUI load."
    exit 1
  }
  foreach lef $::env(LEF_FILES) {
    read_lef $lef
  }
}

proc pin3d_load_design_for_gui {design_file sdc_file} {
  source [file join $::env(OPENROAD_SCRIPTS_DIR) read_liberty.tcl]

  set ext [string tolower [file extension $design_file]]
  switch -- $ext {
    ".def" {
      pin3d_read_lefs
      read_def $design_file
    }
    ".odb" -
    ".db" {
      read_db $design_file
    }
    ".v" {
      pin3d_read_lefs
      read_verilog $design_file
      if {[info exists ::env(DESIGN_NAME)] && $::env(DESIGN_NAME) ne ""} {
        puts "Linking design $::env(DESIGN_NAME)..."
        link_design $::env(DESIGN_NAME)
      }
      set def_file [file rootname $design_file].def
      if {[file exists $def_file]} {
        read_def -floorplan_initialize $def_file
      }
    }
    default {
      puts stderr "ERROR: unsupported design file extension '$ext' for $design_file"
      exit 1
    }
  }

  if {$sdc_file ne "" && [file exists $sdc_file]} {
    read_sdc $sdc_file
    if {[info exists ::env(PLATFORM_DIR)] && [file exists $::env(PLATFORM_DIR)/derate.tcl]} {
      source $::env(PLATFORM_DIR)/derate.tcl
    }
    if {[info exists ::env(SET_RC_TCL)] && $::env(SET_RC_TCL) ne "" && [file exists $::env(SET_RC_TCL)]} {
      source $::env(SET_RC_TCL)
    }
  }
}

set handoff_tcl [file normalize $::env(HANDOFF_TCL)]
if {![file exists $handoff_tcl]} {
  puts stderr "ERROR: handoff manifest not found: $handoff_tcl"
  exit 1
}

source $handoff_tcl

if {![info exists ::handoff::record]} {
  puts stderr "ERROR: handoff manifest did not define ::handoff::record"
  exit 1
}

set handoff_record $::handoff::record
set stage_name [pin3d_dict_get $handoff_record stage]
set stage_label [pin3d_dict_get $handoff_record stage_label $stage_name]

foreach key {results_dir objects_dir log_dir} {
  set value [pin3d_dict_get $handoff_record $key]
  if {$value ne ""} {
    set ::env([string toupper $key]) [pin3d_normalize_optional $value]
  }
}

set design_file [pin3d_select_design_input $handoff_record]
if {$design_file eq ""} {
  puts stderr "ERROR: no existing DEF/ODB found in handoff manifest: $handoff_tcl"
  exit 1
}

set sdc_file [pin3d_select_sdc_input $handoff_record]

unset -nocomplain ::env(DEF_FILE)
unset -nocomplain ::env(ODB_FILE)
unset -nocomplain ::env(SDC_FILE)

switch -- [file extension $design_file] {
  ".odb" -
  ".db" {
    set ::env(ODB_FILE) $design_file
  }
  default {
    set ::env(DEF_FILE) $design_file
  }
}

if {$sdc_file ne ""} {
  set ::env(SDC_FILE) $sdc_file
}

puts "\[INFO\]\[GUI\] handoff=$handoff_tcl"
puts "\[INFO\]\[GUI\] stage=$stage_name label=$stage_label"
puts "\[INFO\]\[GUI\] design_file=$design_file"
if {$sdc_file ne ""} {
  puts "\[INFO\]\[GUI\] sdc_file=$sdc_file"
}
if {[info exists ::env(LEF_FILES)]} {
  puts "\[INFO\]\[GUI\] lef_view=$::env(LEF_FILES)"
}

pin3d_load_design_for_gui $design_file $sdc_file

source $::env(OPENROAD_SCRIPTS_DIR)/build_hierarchy.tcl
set summary [::hier_builder::rebuild_db_hierarchy_from_block]
puts "\[INFO\]\[GUI\] restored module hierarchy: modules=[dict get $summary module_count] modinsts=[dict get $summary modinst_count] assigned_insts=[dict get $summary assigned_inst_count]"

if {[llength [info commands gui::show]] > 0} {
  gui::show
}
