#
# build_hierarchy.tcl
#
# Reconstruct an inferred module hierarchy for the current OpenROAD block from
# hierarchical instance names that were flattened into DEF component names.
#
# Important limitation:
# - The result is a pseudo hierarchy inferred from instance paths.
# - It reconstructs parent/child relationships between module instances.
# - It does not recover canonical RTL module *types* when multiple instances
#   share the same underlying definition.
#

namespace eval ::hier_builder {
  variable default_delimiter "/"
}

proc ::hier_builder::is_null_odb_obj {obj} {
  return [expr {$obj eq "" || $obj eq "NULL"}]
}

proc ::hier_builder::require_block {{block ""} {context "hier_builder"}} {
  if {$block eq ""} {
    set block [ord::get_db_block]
  }
  if {[::hier_builder::is_null_odb_obj $block]} {
    error "$context: OpenROAD block is not initialized"
  }
  return $block
}

proc ::hier_builder::normalize_name {name} {
  set t [string trim $name]
  if {$t eq ""} {
    return $t
  }
  if {[string index $t 0] eq "\\"} {
    set t [string range $t 1 end]
  }
  return [string map [list {\[} {[} {\]} {]}] $t]
}

proc ::hier_builder::path_join {segments {delimiter "/"}} {
  if {[llength $segments] == 0} {
    return ""
  }
  return [join $segments $delimiter]
}

proc ::hier_builder::resolve_design_name {block design_name} {
  if {$design_name ne ""} {
    return $design_name
  }
  return [$block getName]
}

proc ::hier_builder::resolve_delimiter {block {delimiter ""}} {
  if {$delimiter ne ""} {
    return $delimiter
  }
  if {![catch {set delimiter [::odb::dbBlock_getHierarchyDelimiter $block]}] && $delimiter ne ""} {
    return $delimiter
  }
  return $::hier_builder::default_delimiter
}

proc ::hier_builder::db_module_name_from_path {path} {
  if {$path eq ""} {
    return ""
  }

  set encoded "__pin3d__"
  foreach ch [split $path ""] {
    if {[string match {[A-Za-z0-9_]} $ch]} {
      append encoded $ch
    } else {
      scan $ch %c code
      append encoded [format "_%02X" $code]
    }
  }
  return $encoded
}

proc ::hier_builder::split_hier_name {name {delimiter "/"}} {
  set norm [::hier_builder::normalize_name $name]
  if {$norm eq ""} {
    return {}
  }
  set parts {}
  foreach part [split $norm $delimiter] {
    if {$part eq ""} {
      continue
    }
    lappend parts $part
  }
  return $parts
}

proc ::hier_builder::module_depth {path {delimiter "/"}} {
  if {$path eq ""} {
    return 0
  }
  return [llength [split $path $delimiter]]
}

proc ::hier_builder::new_module_record {path parent_path short_name delimiter} {
  return [dict create \
    path $path \
    name $short_name \
    parent_path $parent_path \
    depth [::hier_builder::module_depth $path $delimiter] \
    child_paths {} \
    direct_inst_names {} \
    direct_insts {} \
    direct_inst_count 0 \
    total_inst_count 0]
}

proc ::hier_builder::ensure_module {module_index_var path top_name {delimiter "/"}} {
  upvar 1 $module_index_var module_index

  if {[dict exists $module_index $path]} {
    return [dict get $module_index $path]
  }

  if {$path eq ""} {
    set root [::hier_builder::new_module_record "" "" $top_name $delimiter]
    dict set module_index "" $root
    return $root
  }

  set parts [split $path $delimiter]
  set short_name [lindex $parts end]
  set parent_path [::hier_builder::path_join [lrange $parts 0 end-1] $delimiter]
  set parent_info [::hier_builder::ensure_module module_index $parent_path $top_name $delimiter]
  set info [::hier_builder::new_module_record $path $parent_path $short_name $delimiter]
  dict set module_index $path $info
  dict lappend parent_info child_paths $path
  dict set module_index $parent_path $parent_info
  return $info
}

proc ::hier_builder::register_instance {module_index_var inst inst_name module_path top_name {delimiter "/"}} {
  upvar 1 $module_index_var module_index

  set module_info [::hier_builder::ensure_module module_index $module_path $top_name $delimiter]
  dict lappend module_info direct_inst_names $inst_name
  dict lappend module_info direct_insts $inst
  dict set module_index $module_path $module_info
}

proc ::hier_builder::finalize_module_counts {module_index} {
  set depth_and_path {}
  dict for {path info} $module_index {
    set child_paths [lsort -dictionary [dict get $info child_paths]]
    set direct_inst_names [lsort -dictionary [dict get $info direct_inst_names]]
    dict set info child_paths $child_paths
    dict set info direct_inst_names $direct_inst_names
    dict set info direct_inst_count [llength $direct_inst_names]
    dict set info total_inst_count [llength $direct_inst_names]
    dict set module_index $path $info
    lappend depth_and_path [list [dict get $info depth] $path]
  }
  set depth_and_path [lsort -decreasing -integer -index 0 $depth_and_path]

  foreach item $depth_and_path {
    set path [lindex $item 1]
    set info [dict get $module_index $path]
    foreach child_path [dict get $info child_paths] {
      dict incr info total_inst_count [dict get $module_index $child_path total_inst_count]
    }
    dict set module_index $path $info
  }

  return $module_index
}

proc ::hier_builder::build_hierarchy_from_block {{block ""} {design_name ""} {delimiter ""}} {
  set block [::hier_builder::require_block $block "build_hierarchy_from_block"]
  set design_name [::hier_builder::resolve_design_name $block $design_name]
  set delimiter [::hier_builder::resolve_delimiter $block $delimiter]

  set module_index [dict create]
  ::hier_builder::ensure_module module_index "" $design_name $delimiter

  foreach inst [::odb::dbBlock_getInsts $block] {
    set inst_name [::hier_builder::normalize_name [$inst getName]]
    if {$inst_name eq ""} {
      continue
    }

    set parts [::hier_builder::split_hier_name $inst_name $delimiter]
    if {[llength $parts] == 0} {
      continue
    }

    set module_path [::hier_builder::path_join [lrange $parts 0 end-1] $delimiter]
    ::hier_builder::register_instance module_index $inst $inst_name $module_path $design_name $delimiter
  }

  set module_index [::hier_builder::finalize_module_counts $module_index]
  return [dict create \
    design_name $design_name \
    delimiter $delimiter \
    module_index $module_index]
}

proc ::hier_builder::get_or_create_root_module {block design_name} {
  set root [::odb::dbBlock_findModule $block $design_name]
  if {![::hier_builder::is_null_odb_obj $root]} {
    return $root
  }

  foreach module [::odb::dbBlock_getModules $block] {
    if {[::hier_builder::is_null_odb_obj [$module getModInst]]} {
      return $module
    }
  }

  return [::odb::dbModule_create $block $design_name]
}

proc ::hier_builder::clear_db_hierarchy {{block ""} {root_module ""}} {
  set block [::hier_builder::require_block $block "clear_db_hierarchy"]

  if {$root_module eq "" || [::hier_builder::is_null_odb_obj $root_module]} {
    set root_module [::hier_builder::get_or_create_root_module $block [$block getName]]
  }

  # First move every leaf instance back to the root module. dbModule::addInst
  # transparently reparents the instance from its previous module.
  foreach inst [::odb::dbBlock_getInsts $block] {
    $root_module addInst $inst
  }

  # Then delete stale modinst/module objects, leaving only the top module.
  foreach modinst [::odb::dbBlock_getModInsts $block] {
    ::odb::dbModInst_destroy $modinst
  }
  foreach module [::odb::dbBlock_getModules $block] {
    if {$module ne $root_module} {
      ::odb::dbModule_destroy $module
    }
  }

  return $root_module
}

proc ::hier_builder::module_children {hierarchy module_path} {
  return [dict get [dict get $hierarchy module_index] $module_path child_paths]
}

proc ::hier_builder::module_direct_insts {hierarchy module_path} {
  return [dict get [dict get $hierarchy module_index] $module_path direct_inst_names]
}

proc ::hier_builder::materialize_hierarchy_to_db {hierarchy {block ""}} {
  set block [::hier_builder::require_block $block "materialize_hierarchy_to_db"]

  set design_name [dict get $hierarchy design_name]
  set module_index [dict get $hierarchy module_index]
  # ODB's hierarchy-aware features key off the database-level flag in addition
  # to the presence of dbModule/dbModInst objects.
  [ord::get_db] setHierarchy 1
  set root_module [::hier_builder::clear_db_hierarchy $block \
    [::hier_builder::get_or_create_root_module $block $design_name]]

  set db_modules [dict create "" $root_module]
  set module_paths {}
  dict for {path info} $module_index {
    if {$path eq ""} {
      continue
    }
    lappend module_paths [list [dict get $info depth] $path]
  }
  set module_paths [lsort -integer -index 0 $module_paths]

  # Create dbModule/dbModInst objects in top-down order so every parent module
  # already exists when its child module instance is created.
  foreach item $module_paths {
    set path [lindex $item 1]
    set info [dict get $module_index $path]
    set parent_path [dict get $info parent_path]
    set short_name [dict get $info name]
    set parent_module [dict get $db_modules $parent_path]
    set db_name [::hier_builder::db_module_name_from_path $path]

    set db_module [::odb::dbBlock_findModule $block $db_name]
    if {[::hier_builder::is_null_odb_obj $db_module]} {
      set db_module [::odb::dbModule_create $block $db_name]
    }

    set modinst [$parent_module findModInst $short_name]
    if {[::hier_builder::is_null_odb_obj $modinst]} {
      set modinst [::odb::dbModInst_create $parent_module $db_module $short_name]
    }
    dict set db_modules $path $db_module
  }

  set assigned_inst_count 0
  dict for {path info} $module_index {
    set db_module [dict get $db_modules $path]
    foreach inst [dict get $info direct_insts] {
      if {[::hier_builder::is_null_odb_obj $inst]} {
        error "materialize_hierarchy_to_db: encountered NULL dbInst while assigning '$path'"
      }
      $db_module addInst $inst
      incr assigned_inst_count
    }
  }

  return [dict create \
    design_name $design_name \
    root_module $root_module \
    module_count [llength [::odb::dbBlock_getModules $block]] \
    modinst_count [llength [::odb::dbBlock_getModInsts $block]] \
    assigned_inst_count $assigned_inst_count]
}

proc ::hier_builder::rebuild_db_hierarchy_from_block {{block ""} {design_name ""} {delimiter ""} {return_hierarchy 0}} {
  set block [::hier_builder::require_block $block "rebuild_db_hierarchy_from_block"]
  set hierarchy [::hier_builder::build_hierarchy_from_block $block $design_name $delimiter]
  set summary [::hier_builder::materialize_hierarchy_to_db $hierarchy $block]
  if {$return_hierarchy} {
    dict set summary hierarchy $hierarchy
  }
  return $summary
}

proc ::hier_builder::_append_report_lines {module_index design_name module_path max_depth out_var} {
  upvar 1 $out_var out

  set info [dict get $module_index $module_path]
  set depth [dict get $info depth]
  if {$max_depth >= 0 && $depth > $max_depth} {
    return
  }

  set indent [string repeat "  " $depth]
  set label [expr {$module_path eq "" ? $design_name : [dict get $info name]}]
  lappend out [format "%s%s  modules=%d direct_insts=%d total_insts=%d" \
    $indent \
    $label \
    [llength [dict get $info child_paths]] \
    [dict get $info direct_inst_count] \
    [dict get $info total_inst_count]]

  foreach child_path [dict get $info child_paths] {
    ::hier_builder::_append_report_lines $module_index $design_name $child_path $max_depth out
  }
}

proc ::hier_builder::format_hierarchy_report {hierarchy {max_depth -1}} {
  set design_name [dict get $hierarchy design_name]
  set module_index [dict get $hierarchy module_index]
  set out [list [format "Hierarchy for %s" $design_name]]
  ::hier_builder::_append_report_lines $module_index $design_name "" $max_depth out
  return [join $out "\n"]
}

proc ::hier_builder::report_hierarchy {hierarchy {max_depth -1}} {
  puts [::hier_builder::format_hierarchy_report $hierarchy $max_depth]
}
