# ============================================================
# handoff_manager.tcl
# Unified OpenROAD handoff registry and read/write helpers.
# The goal is to keep stage-to-stage DEF/Verilog/SDC management
# consistent across the 3D flow.
# ============================================================

if {![llength [info commands _get]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
}

proc _handoff_stage_dict {stage stage_label results_dir objects_dir log_dir payload} {
  set handoff_dir [file join $results_dir "handoffs"]
  file mkdir $handoff_dir
  set base [dict create \
    stage $stage \
    stage_label $stage_label \
    results_dir $results_dir \
    objects_dir $objects_dir \
    log_dir $log_dir \
    manifest_out [file join $handoff_dir "${stage}.tcl"] \
    def_in "" \
    v_in "" \
    sdc_in "" \
    odb_in "" \
    def_out "" \
    v_out "" \
    sdc_out "" \
    odb_out "" \
    image_out "" \
    summary_out "" \
    csv_out "" \
    def_aliases {} \
    v_aliases {} \
    sdc_aliases {} \
    odb_aliases {}]
  return [dict merge $base $payload]
}

proc handoff_stage_paths {stage {results_dir ""} {objects_dir ""} {log_dir ""}} {
  if {$results_dir eq ""} {
    set results_dir [_get RESULTS_DIR]
  }
  if {$objects_dir eq ""} {
    set objects_dir [_get OBJECTS_DIR]
  }
  if {$log_dir eq ""} {
    set log_dir [_get LOG_DIR]
  }

  switch -- $stage {
    floorplan-3d {
      return [_handoff_stage_dict $stage "ord-3d-floorplan" $results_dir $objects_dir $log_dir [dict create \
        v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.fp.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_3_floorplan_3d.def"] \
        v_out [file join $results_dir "2_3_floorplan_3d.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        image_out [file join $log_dir "2_3_floorplan_3d.webp"]]]
    }
    io-place {
      return [_handoff_stage_dict $stage "ord-3d-io" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_3_floorplan_3d.def"] \
        v_in [file join $results_dir "2_3_floorplan_3d.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_4_floorplan_io.def"] \
        v_out [file join $results_dir "2_4_floorplan_io.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        image_out [file join $log_dir "2_4_floorplan_io.webp"]]]
    }
    split-net {
      return [_handoff_stage_dict $stage "ord-3d-split-net" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_4_floorplan_io.def"] \
        v_in [file join $results_dir "2_4_floorplan_io.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_4_floorplan_io.def"] \
        v_out [file join $results_dir "2_4_floorplan_io.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        image_out [file join $log_dir "2_4_floorplan_split.webp"] \
        summary_out [file join $log_dir "split_net.summary.rpt"]]]
    }
    macro-upper {
      return [_handoff_stage_dict $stage "ord-place-macro-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_4_floorplan_io.def"] \
        v_in [file join $results_dir "2_4_floorplan_io.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_5_place_macro_upper.def"] \
        v_out [file join $results_dir "2_5_place_macro_upper.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        image_out [file join $log_dir "2_5_place_macro_upper.webp"]]]
    }
    macro-bottom {
      return [_handoff_stage_dict $stage "ord-place-macro-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_5_place_macro_upper.def"] \
        v_in [file join $results_dir "2_5_place_macro_upper.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_5_place_macro_bottom.def"] \
        v_out [file join $results_dir "2_5_place_macro_bottom.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        image_out [file join $log_dir "2_5_place_macro_bottom.webp"]]]
    }
    pdn-bottom {
      return [_handoff_stage_dict $stage "ord-3d-pdn-only-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_5_place_macro_bottom.def"] \
        v_in [file join $results_dir "2_5_place_macro_bottom.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_6_floorplan_pdn_bottom.def"] \
        v_out [file join $results_dir "2_6_floorplan_pdn_bottom.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        image_out [file join $log_dir "2_6_floorplan_pdn_bottom.webp"]]]
    }
    pdn-upper {
      return [_handoff_stage_dict $stage "ord-3d-pdn-only-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_6_floorplan_pdn_bottom.def"] \
        v_in [file join $results_dir "2_6_floorplan_pdn_bottom.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_6_floorplan_pdn.def"] \
        v_out [file join $results_dir "2_6_floorplan_pdn.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        def_aliases [list [file join $results_dir "2_floorplan.def"]] \
        v_aliases [list [file join $results_dir "2_floorplan.v"]] \
        image_out [file join $log_dir "2_6_floorplan_pdn_upper.webp"]]]
    }
    place-init {
      return [_handoff_stage_dict $stage "ord-place-init" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_floorplan.def"] \
        v_in [file join $results_dir "2_floorplan.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        image_out [file join $log_dir "3_place_init.webp"]]]
    }
    place-init-upper {
      return [_handoff_stage_dict $stage "ord-place-init-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        image_out [file join $log_dir "3_place_init_upper.webp"]]]
    }
    place-init-bottom {
      return [_handoff_stage_dict $stage "ord-place-init-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        image_out [file join $log_dir "3_place_init_bottom.webp"]]]
    }
    place-upper {
      return [_handoff_stage_dict $stage "ord-place-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        image_out [file join $log_dir "3_place_upper.webp"]]]
    }
    place-bottom {
      return [_handoff_stage_dict $stage "ord-place-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        image_out [file join $log_dir "3_place_bottom.webp"]]]
    }
    gp2lg {
      return [_handoff_stage_dict $stage "ord-gp2lg" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.def"] \
        v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.def"] \
        v_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"]]]
    }
    legalize-upper {
      return [_handoff_stage_dict $stage "ord-legalize-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.def"] \
        v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.def"] \
        v_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.v"] \
        sdc_out [file join $results_dir "3_place.sdc"] \
        def_aliases [list [file join $results_dir "3_place.def"]] \
        v_aliases [list [file join $results_dir "3_place.v"]] \
        image_out [file join $log_dir "3_5_lg_upper.webp"]]]
    }
    legalize-bottom {
      return [_handoff_stage_dict $stage "ord-legalize-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.def"] \
        v_in [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.def"] \
        v_out [file join $results_dir "${::env(DESIGN_NAME)}_3D.lg.v"] \
        sdc_out [file join $results_dir "3_place.sdc"] \
        def_aliases [list [file join $results_dir "3_place.def"]] \
        v_aliases [list [file join $results_dir "3_place.v"]] \
        image_out [file join $log_dir "3_4_lg_bottom.webp"]]]
    }
    cts {
      return [_handoff_stage_dict $stage "ord-cts" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "3_place.def"] \
        v_in [file join $results_dir "3_place.v"] \
        sdc_in [file join $results_dir "3_place.sdc"] \
        def_out [file join $results_dir "4_0_cts.def"] \
        v_out [file join $results_dir "4_0_cts.v"] \
        sdc_out [file join $results_dir "4_0_cts.sdc"] \
        odb_out [file join $results_dir "4_0_cts.odb"] \
        image_out [file join $log_dir "4_0_cts.webp"]]]
    }
    cts-post {
      return [_handoff_stage_dict $stage "ord-cts-post" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "4_0_cts.def"] \
        v_in [file join $results_dir "4_0_cts.v"] \
        sdc_in [file join $results_dir "4_0_cts.sdc"] \
        def_out [file join $results_dir "4_cts.def"] \
        v_out [file join $results_dir "4_cts.v"] \
        sdc_out [file join $results_dir "4_cts.sdc"] \
        odb_out [file join $results_dir "4_cts.odb"] \
        image_out [file join $log_dir "4_cts_post.webp"]]]
    }
    route-global {
      return [_handoff_stage_dict $stage "ord-route-global" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "4_cts.def"] \
        v_in [file join $results_dir "4_cts.v"] \
        sdc_in [file join $results_dir "4_cts.sdc"] \
        odb_out [file join $results_dir "5_1_grt.odb"] \
        sdc_out [file join $results_dir "5_1_grt.sdc"]]]
    }
    route-detail {
      return [_handoff_stage_dict $stage "ord-route-detail" $results_dir $objects_dir $log_dir [dict create \
        odb_in [file join $results_dir "5_1_grt.odb"] \
        sdc_in [file join $results_dir "5_1_grt.sdc"] \
        def_out [file join $results_dir "5_route.def"] \
        v_out [file join $results_dir "5_route.v"] \
        sdc_out [file join $results_dir "5_route.sdc"] \
        odb_out [file join $results_dir "5_route.odb"]]]
    }
    route {
      return [_handoff_stage_dict $stage "ord-route" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "4_cts.def"] \
        v_in [file join $results_dir "4_cts.v"] \
        sdc_in [file join $results_dir "4_cts.sdc"] \
        odb_in [file join $results_dir "5_1_grt.odb"] \
        def_out [file join $results_dir "5_route.def"] \
        v_out [file join $results_dir "5_route.v"] \
        sdc_out [file join $results_dir "5_route.sdc"] \
        odb_out [file join $results_dir "5_route.odb"]]]
    }
    final {
      return [_handoff_stage_dict $stage "ord-final" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "5_route.def"] \
        v_in [file join $results_dir "5_route.v"] \
        sdc_in [file join $results_dir "5_route.sdc"] \
        def_out [file join $results_dir "6_final.def"] \
        v_out [file join $results_dir "6_final.v"] \
        sdc_out [file join $results_dir "6_final.sdc"] \
        odb_out [file join $results_dir "6_final.odb"] \
        summary_out [file join $log_dir "final_summary.txt"]]]
    }
    default {
      error "Unknown OpenROAD handoff stage '$stage'"
    }
  }
}

proc handoff_bind_stage_io {stage_paths} {
  set bindings {
    DEF_IN def_in
    V_IN v_in
    SDC_IN sdc_in
    ODB_IN odb_in
    DEF_OUT def_out
    V_OUT v_out
    SDC_OUT sdc_out
    ODB_OUT odb_out
    IMAGE_OUT image_out
    SUMMARY_OUT summary_out
    CSV_OUT csv_out
    MANIFEST_OUT manifest_out
  }
  foreach {var key} $bindings {
    if {[dict exists $stage_paths $key]} {
      uplevel 1 [list set $var [dict get $stage_paths $key]]
    } else {
      uplevel 1 [list set $var ""]
    }
  }
  foreach {var key} {
    DEF_ALIASES def_aliases
    V_ALIASES v_aliases
    SDC_ALIASES sdc_aliases
    ODB_ALIASES odb_aliases
  } {
    if {[dict exists $stage_paths $key]} {
      uplevel 1 [list set $var [dict get $stage_paths $key]]
    } else {
      uplevel 1 [list set $var {}]
    }
  }
}

proc handoff_log_paths {stage_paths} {
  puts "INFO(OR): handoff stage=[dict get $stage_paths stage_label]"
  foreach key {def_in v_in sdc_in odb_in def_out v_out sdc_out odb_out manifest_out summary_out} {
    if {[dict exists $stage_paths $key]} {
      set value [dict get $stage_paths $key]
      if {$value ne ""} {
        puts "INFO(OR):   $key=$value"
      }
    }
  }
}

proc handoff_write_manifest {stage_paths} {
  set path [dict get $stage_paths manifest_out]
  set fh [open $path w]
  puts $fh "namespace eval ::handoff {}"
  puts $fh "set ::handoff::record [list $stage_paths]"
  close $fh
}

proc handoff_copy_if_needed {src dst} {
  if {$src eq "" || $dst eq ""} {
    return
  }
  if {![file exists $src]} {
    return
  }
  if {[file normalize $src] eq [file normalize $dst]} {
    return
  }
  file copy -force $src $dst
}

proc handoff_copy_aliases {src aliases} {
  foreach alias $aliases {
    handoff_copy_if_needed $src $alias
  }
}

proc handoff_write_stage_outputs {stage_paths args} {
  array set opt {
    -write_db 0
    -write_def 1
    -write_verilog 1
    -write_sdc 0
    -copy_sdc 0
    -write_image 0
    -write_manifest 1
  }
  if {([llength $args] % 2) != 0} {
    error "handoff_write_stage_outputs: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "handoff_write_stage_outputs: unknown option $k"
    }
    set opt($k) $v
  }

  if {$opt(-write_db) && [dict get $stage_paths odb_out] ne ""} {
    write_db [dict get $stage_paths odb_out]
    handoff_copy_aliases [dict get $stage_paths odb_out] [dict get $stage_paths odb_aliases]
  }
  if {$opt(-write_def) && [dict get $stage_paths def_out] ne ""} {
    write_def [dict get $stage_paths def_out]
    handoff_copy_aliases [dict get $stage_paths def_out] [dict get $stage_paths def_aliases]
  }
  if {$opt(-write_verilog) && [dict get $stage_paths v_out] ne ""} {
    write_verilog [dict get $stage_paths v_out]
    handoff_copy_aliases [dict get $stage_paths v_out] [dict get $stage_paths v_aliases]
  }
  if {$opt(-write_sdc) && [dict get $stage_paths sdc_out] ne ""} {
    write_sdc [dict get $stage_paths sdc_out]
    handoff_copy_aliases [dict get $stage_paths sdc_out] [dict get $stage_paths sdc_aliases]
  } elseif {$opt(-copy_sdc)} {
    handoff_copy_if_needed [dict get $stage_paths sdc_in] [dict get $stage_paths sdc_out]
    handoff_copy_aliases [dict get $stage_paths sdc_out] [dict get $stage_paths sdc_aliases]
  }
  if {$opt(-write_image) && [dict get $stage_paths image_out] ne "" && [llength [info commands save_image]]} {
    set display_ok [expr {[info exists ::env(DISPLAY)] && $::env(DISPLAY) ne ""}]
    set qt_offscreen [expr {[info exists ::env(QT_QPA_PLATFORM)] && $::env(QT_QPA_PLATFORM) eq "offscreen"}]
    if {$display_ok || $qt_offscreen} {
      if {[catch {save_image -resolution 0.1 [dict get $stage_paths image_out]} err]} {
        puts "WARN(OR): failed to write image [dict get $stage_paths image_out] : $err"
      }
    } else {
      puts "INFO(OR): skip image output [dict get $stage_paths image_out] in headless mode"
    }
  }
  if {$opt(-write_manifest)} {
    handoff_write_manifest $stage_paths
  }
}
