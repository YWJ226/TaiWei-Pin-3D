# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# handoff_manager.tcl
# Unified Cadence handoff registry and read/write helpers.
# The goal is to keep stage-to-stage DEF/Verilog/SDC management
# consistent across the 3D flow.
# ============================================================

if {![llength [info commands _get]]} {
  source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
}
if {![info exists ::DESIGN]} {
  source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
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
    enc_in "" \
    def_out "" \
    v_out "" \
    sdc_out "" \
    enc_out "" \
    png_out "" \
    wrapper_v "" \
    wrapper_sdc "" \
    csv_out "" \
    summary_out "" \
    def_aliases {} \
    v_aliases {} \
    sdc_aliases {}]
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
    preplace {
      return [_handoff_stage_dict $stage "cds-preplace" $results_dir $objects_dir $log_dir [dict create \
        v_in [file join $results_dir "1_synth.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_2_floorplan_io.def"] \
        v_out [file join $results_dir "2_2_floorplan_io.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        enc_out [file join $objects_dir "2_2_floorplan_io.enc"] \
        png_out [file join $log_dir "2_2_floorplan_io.png"]]]
    }
    pdn-3d {
      return [_handoff_stage_dict $stage "cds-3d-pdn" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::DESIGN}_3D.fp.def"] \
        v_in [file join $results_dir "${::DESIGN}_3D.fp.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_floorplan.def"] \
        v_out [file join $results_dir "2_floorplan.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        png_out [file join $log_dir "2_pdn.png"]]]
    }
    floorplan-3d {
      return [_handoff_stage_dict $stage "cds-3d-floorplan" $results_dir $objects_dir $log_dir [dict create \
        v_in [file join $results_dir "${::DESIGN}_3D.fp.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_3_floorplan_3d.def"] \
        v_out [file join $results_dir "2_3_floorplan_3d.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        png_out [file join $log_dir "2_3_floorplan_3d.png"]]]
    }
    io-place {
      return [_handoff_stage_dict $stage "cds-3d-io" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_3_floorplan_3d.def"] \
        v_in [file join $results_dir "2_3_floorplan_3d.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_4_floorplan_io.def"] \
        v_out [file join $results_dir "2_4_floorplan_io.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        png_out [file join $log_dir "2_4_floorplan_io.png"]]]
    }
    split-net {
      return [_handoff_stage_dict $stage "cds-3d-split-net" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_4_floorplan_io.def"] \
        v_in [file join $results_dir "2_4_floorplan_io.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_4_floorplan_io.def"] \
        v_out [file join $results_dir "2_4_floorplan_io.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_3d_after_split_net.enc"] \
        png_out [file join $log_dir "2_4_floorplan_split.png"]]]
    }
    macro-upper {
      return [_handoff_stage_dict $stage "cds-place-macro-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_4_floorplan_io.def"] \
        v_in [file join $results_dir "2_4_floorplan_io.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_5_place_macro_upper.def"] \
        v_out [file join $results_dir "2_5_place_macro_upper.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        png_out [file join $log_dir "2_5_place_macro_upper.png"]]]
    }
    macro-bottom {
      return [_handoff_stage_dict $stage "cds-place-macro-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_5_place_macro_upper.def"] \
        v_in [file join $results_dir "2_5_place_macro_upper.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_5_place_macro_bottom.def"] \
        v_out [file join $results_dir "2_5_place_macro_bottom.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        png_out [file join $log_dir "2_5_place_macro_bottom.png"]]]
    }
    pdn-bottom {
      return [_handoff_stage_dict $stage "cds-3d-pdn-only-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_5_place_macro_bottom.def"] \
        v_in [file join $results_dir "2_5_place_macro_bottom.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_6_floorplan_pdn_bottom.def"] \
        v_out [file join $results_dir "2_6_floorplan_pdn_bottom.v"] \
        sdc_out [file join $results_dir "1_synth.sdc"] \
        png_out [file join $log_dir "2_6_floorplan_pdn_bottom.png"]]]
    }
    pdn-upper {
      return [_handoff_stage_dict $stage "cds-3d-pdn-only-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_6_floorplan_pdn_bottom.def"] \
        v_in [file join $results_dir "2_6_floorplan_pdn_bottom.v"] \
        sdc_in [file join $results_dir "1_synth.sdc"] \
        def_out [file join $results_dir "2_6_floorplan_pdn.def"] \
        v_out [file join $results_dir "2_6_floorplan_pdn.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        def_aliases [list [file join $results_dir "2_floorplan.def"]] \
        v_aliases [list [file join $results_dir "2_floorplan.v"]] \
        png_out [file join $log_dir "2_6_floorplan_pdn_upper.png"]]]
    }
    gp2lg {
      return [_handoff_stage_dict $stage "cds-gp2lg" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_in [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::DESIGN}_3D.lg.def"] \
        v_out [file join $results_dir "${::DESIGN}_3D.lg.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"]]]
    }
    place-init {
      return [_handoff_stage_dict $stage "cds-place-init" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "2_floorplan.def"] \
        v_in [file join $results_dir "2_floorplan.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_out [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        png_out [file join $log_dir "3_place_init.png"]]]
    }
    place-init-upper {
      return [_handoff_stage_dict $stage "cds-place-init-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_in [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_out [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        png_out [file join $log_dir "3_place_init_upper.png"]]]
    }
    place-init-bottom {
      return [_handoff_stage_dict $stage "cds-place-init-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_in [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_out [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        png_out [file join $log_dir "3_place_init_bottom.png"]]]
    }
    place-upper {
      return [_handoff_stage_dict $stage "cds-place-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_in [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_out [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_3d_after_upper.enc"] \
        png_out [file join $log_dir "3_place_upper.png"]]]
    }
    place-bottom {
      return [_handoff_stage_dict $stage "cds-place-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_in [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::DESIGN}_3D.tmp.def"] \
        v_out [file join $results_dir "${::DESIGN}_3D.tmp.v"] \
        sdc_out [file join $results_dir "2_floorplan.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_3d_after_bottom.enc"] \
        png_out [file join $log_dir "3_place_bottom.png"]]]
    }
    legalize-upper {
      return [_handoff_stage_dict $stage "cds-legalize-upper" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::DESIGN}_3D.lg.def"] \
        v_in [file join $results_dir "${::DESIGN}_3D.lg.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::DESIGN}_3D.lg.def"] \
        v_out [file join $results_dir "${::DESIGN}_3D.lg.v"] \
        sdc_out [file join $results_dir "3_place.sdc"] \
        def_aliases [list [file join $results_dir "3_place.def"]] \
        v_aliases [list [file join $results_dir "3_place.v"]] \
        png_out [file join $log_dir "4_2_lg_upper.png"]]]
    }
    legalize-bottom {
      return [_handoff_stage_dict $stage "cds-legalize-bottom" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "${::DESIGN}_3D.lg.def"] \
        v_in [file join $results_dir "${::DESIGN}_3D.lg.v"] \
        sdc_in [file join $results_dir "2_floorplan.sdc"] \
        def_out [file join $results_dir "${::DESIGN}_3D.lg.def"] \
        v_out [file join $results_dir "${::DESIGN}_3D.lg.v"] \
        sdc_out [file join $results_dir "3_place.sdc"] \
        def_aliases [list [file join $results_dir "3_place.def"]] \
        v_aliases [list [file join $results_dir "3_place.v"]] \
        png_out [file join $log_dir "4_2_lg_bottom.png"]]]
    }
    cts-owner-tree {
      return [_handoff_stage_dict $stage "cds-cts-owner-tree" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "3_place.def"] \
        v_in [file join $results_dir "3_place.v"] \
        sdc_in [file join $results_dir "3_place.sdc"] \
        def_out [file join $results_dir "4_0_cts_owner_tree.def"] \
        v_out [file join $results_dir "4_0_cts_owner_tree.v"] \
        sdc_out [file join $results_dir "4_0_cts_owner_tree.sdc"] \
        wrapper_v [file join $results_dir "4_0_cts_owner_tree.wrapper.v"] \
        wrapper_sdc [file join $results_dir "4_0_cts_owner_tree.wrapper.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_cts_owner_tree.enc"] \
        png_out [file join $log_dir "4_0_cts_owner_tree.png"]]]
    }
    cts-receive-opt {
      return [_handoff_stage_dict $stage "cds-cts-receive-opt" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "4_0_cts_owner_tree.def"] \
        v_in [file join $results_dir "4_0_cts_owner_tree.v"] \
        sdc_in [file join $results_dir "4_0_cts_owner_tree.sdc"] \
        def_out [file join $results_dir "4_1_cts_receive_opt.def"] \
        v_out [file join $results_dir "4_1_cts_receive_opt.v"] \
        sdc_out [file join $results_dir "4_1_cts_receive_opt.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_cts_receive_opt.enc"] \
        png_out [file join $log_dir "4_1_cts_receive_opt.png"]]]
    }
    cts-finalize {
      return [_handoff_stage_dict $stage "cds-cts-finalize" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "4_1_cts_receive_opt.def"] \
        v_in [file join $results_dir "4_1_cts_receive_opt.v"] \
        sdc_in [file join $results_dir "4_1_cts_receive_opt.sdc"] \
        def_out [file join $results_dir "4_3_cts_finalize.def"] \
        v_out [file join $results_dir "4_3_cts_finalize.v"] \
        sdc_out [file join $results_dir "4_3_cts_finalize.sdc"] \
        def_aliases [list [file join $results_dir "4_cts.def"]] \
        v_aliases [list [file join $results_dir "4_cts.v"]] \
        sdc_aliases [list [file join $results_dir "4_cts.sdc"]] \
        enc_out [file join $objects_dir "${::DESIGN}_cts_finalize.enc"] \
        png_out [file join $log_dir "4_3_cts_finalize.png"]]]
    }
    cts-legacy {
      return [_handoff_stage_dict $stage "cds-cts-legacy" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "3_place.def"] \
        v_in [file join $results_dir "3_place.v"] \
        sdc_in [file join $results_dir "3_place.sdc"] \
        def_out [file join $results_dir "4_1_cts.def"] \
        v_out [file join $results_dir "4_1_cts.v"] \
        sdc_out [file join $results_dir "4_1_cts.sdc"] \
        def_aliases [list [file join $results_dir "4_cts.def"]] \
        v_aliases [list [file join $results_dir "4_cts.v"]] \
        sdc_aliases [list [file join $results_dir "4_cts.sdc"]] \
        png_out [file join $log_dir "4_1_cts.png"]]]
    }
    route-only {
      return [_handoff_stage_dict $stage "cds-route-only" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "4_cts.def"] \
        v_in [file join $results_dir "4_cts.v"] \
        sdc_in [file join $results_dir "4_cts.sdc"] \
        def_out [file join $results_dir "5_0_route.def"] \
        v_out [file join $results_dir "5_0_route.v"] \
        sdc_out [file join $results_dir "5_0_route.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_route_only.enc"] \
        png_out [file join $log_dir "5_0_route.png"]]]
    }
    postroute-receive {
      return [_handoff_stage_dict $stage "cds-postroute-receive" $results_dir $objects_dir $log_dir [dict create \
        enc_in [file join $objects_dir "${::DESIGN}_route_only.enc.dat"] \
        def_in [file join $results_dir "5_0_route.def"] \
        v_in [file join $results_dir "5_0_route.v"] \
        sdc_in [file join $results_dir "5_0_route.sdc"] \
        def_out [file join $results_dir "5_1_postroute_receive.def"] \
        v_out [file join $results_dir "5_1_postroute_receive.v"] \
        sdc_out [file join $results_dir "5_1_postroute_receive.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_postroute_receive.enc"] \
        png_out [file join $log_dir "5_1_postroute_receive.png"]]]
    }
    postroute-owner {
      return [_handoff_stage_dict $stage "cds-postroute-owner" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "5_1_postroute_receive.def"] \
        v_in [file join $results_dir "5_1_postroute_receive.v"] \
        sdc_in [file join $results_dir "5_1_postroute_receive.sdc"] \
        def_out [file join $results_dir "5_2_postroute_owner.def"] \
        v_out [file join $results_dir "5_2_postroute_owner.v"] \
        sdc_out [file join $results_dir "5_2_postroute_owner.sdc"] \
        def_aliases [list [file join $results_dir "5_route.def"]] \
        v_aliases [list [file join $results_dir "5_route.v"]] \
        sdc_aliases [list [file join $results_dir "5_route.sdc"]] \
        enc_out [file join $objects_dir "${::DESIGN}_postroute_owner.enc"] \
        png_out [file join $log_dir "5_2_postroute_owner.png"]]]
    }
    route-legacy {
      return [_handoff_stage_dict $stage "cds-route" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "4_cts.def"] \
        v_in [file join $results_dir "4_cts.v"] \
        sdc_in [file join $results_dir "4_cts.sdc"] \
        def_out [file join $results_dir "5_route.def"] \
        v_out [file join $results_dir "5_route.v"] \
        sdc_out [file join $results_dir "5_route.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_postRoute.enc"] \
        png_out [file join $log_dir "5_route.png"]]]
    }
    final {
      return [_handoff_stage_dict $stage "cds-final" $results_dir $objects_dir $log_dir [dict create \
        def_in [file join $results_dir "5_route.def"] \
        v_in [file join $results_dir "5_route.v"] \
        sdc_in [file join $results_dir "5_route.sdc"] \
        png_out [file join $log_dir "6_final.png"] \
        csv_out [file join $log_dir "final_metrics.csv"] \
        summary_out [file join $log_dir "final_summary.txt"]]]
    }
    final-restore {
      return [_handoff_stage_dict $stage "cds-restore" $results_dir $objects_dir $log_dir [dict create \
        enc_in [file join $objects_dir "${::DESIGN}_postRoute.enc.dat"] \
        def_in [file join $results_dir "5_route.def"] \
        v_in [file join $results_dir "5_route.v"] \
        sdc_in [file join $results_dir "5_route.sdc"] \
        png_out [file join $log_dir "6_final.png"] \
        csv_out [file join $log_dir "final_metrics.csv"] \
        summary_out [file join $log_dir "final_summary.txt"]]]
    }
    default {
      error "Unsupported handoff stage '$stage'."
    }
  }
}

proc handoff_get {stage_paths key {default_value ""}} {
  if {[dict exists $stage_paths $key]} {
    return [dict get $stage_paths $key]
  }
  return $default_value
}

proc handoff_copy_file_if_exists {src dst} {
  if {$src eq "" || $dst eq ""} {
    return
  }
  if {$src eq $dst} {
    return
  }
  if {[file exists $src]} {
    file copy -force $src $dst
  }
}

proc handoff_require_inputs {stage_paths keys} {
  set stage_label [handoff_get $stage_paths stage_label [handoff_get $stage_paths stage]]
  foreach key $keys {
    set path [handoff_get $stage_paths $key]
    if {$path eq ""} {
      error "Stage '$stage_label' is missing required handoff key '$key'."
    }
    if {![file exists $path]} {
      error "Stage '$stage_label' is missing required handoff file '$key': $path"
    }
  }
}

proc handoff_log_paths {stage_paths} {
  set stage_label [handoff_get $stage_paths stage_label [handoff_get $stage_paths stage]]
  puts "INFO: Handoff stage '$stage_label'"
  foreach key {def_in v_in sdc_in enc_in def_out v_out sdc_out enc_out png_out csv_out summary_out manifest_out} {
    set value [handoff_get $stage_paths $key]
    if {$value ne ""} {
      puts "INFO:   $key -> $value"
    }
  }
}

proc handoff_bind_stage_io {stage_paths} {
  upvar 1 LOG_DIR LOG_DIR
  upvar 1 RESULTS_DIR RESULTS_DIR
  upvar 1 OBJECTS_DIR OBJECTS_DIR
  upvar 1 REPORTS_DIR REPORTS_DIR
  upvar 1 DEF_IN DEF_IN
  upvar 1 V_IN V_IN
  upvar 1 SDC_IN SDC_IN
  upvar 1 ENC_IN ENC_IN
  upvar 1 DEF_OUT DEF_OUT
  upvar 1 V_OUT V_OUT
  upvar 1 SDC_OUT SDC_OUT
  upvar 1 ENC_OUT ENC_OUT
  upvar 1 PNG_OUT PNG_OUT
  upvar 1 CSV_OUT CSV_OUT
  upvar 1 SUMMARY_OUT SUMMARY_OUT
  upvar 1 MANIFEST_OUT MANIFEST_OUT
  upvar 1 WRAPPER_V WRAPPER_V
  upvar 1 WRAPPER_SDC WRAPPER_SDC

  set LOG_DIR [handoff_get $stage_paths log_dir [_get LOG_DIR]]
  set RESULTS_DIR [handoff_get $stage_paths results_dir [_get RESULTS_DIR]]
  set OBJECTS_DIR [handoff_get $stage_paths objects_dir [_get OBJECTS_DIR]]
  set REPORTS_DIR [_get REPORTS_DIR]
  set DEF_IN [handoff_get $stage_paths def_in]
  set V_IN [handoff_get $stage_paths v_in]
  set SDC_IN [handoff_get $stage_paths sdc_in]
  set ENC_IN [handoff_get $stage_paths enc_in]
  set DEF_OUT [handoff_get $stage_paths def_out]
  set V_OUT [handoff_get $stage_paths v_out]
  set SDC_OUT [handoff_get $stage_paths sdc_out]
  set ENC_OUT [handoff_get $stage_paths enc_out]
  set PNG_OUT [handoff_get $stage_paths png_out]
  set CSV_OUT [handoff_get $stage_paths csv_out]
  set SUMMARY_OUT [handoff_get $stage_paths summary_out]
  set MANIFEST_OUT [handoff_get $stage_paths manifest_out]
  set WRAPPER_V [handoff_get $stage_paths wrapper_v]
  set WRAPPER_SDC [handoff_get $stage_paths wrapper_sdc]
}

proc handoff_prepare_init_globals {stage_paths} {
  set v_in [handoff_get $stage_paths v_in]
  set ::init_lef_file $::lefs
  set ::init_mmmc_file ""
  set ::init_design_settop 1
  set ::init_top_cell $::DESIGN
  set ::init_verilog $v_in
  set ::init_design_netlisttype "Verilog"
}

proc handoff_init_design_from_paths {stage_paths args} {
  array set opt {
    -require_def 1
  }
  array set opt $args

  if {$opt(-require_def)} {
    handoff_require_inputs $stage_paths {v_in sdc_in def_in}
  } else {
    handoff_require_inputs $stage_paths {v_in sdc_in}
  }

  handoff_prepare_init_globals $stage_paths
  init_design -setup {WC_VIEW} -hold {BC_VIEW}
  _common_setup

  if {$opt(-require_def)} {
    defIn [handoff_get $stage_paths def_in]
  }
}

proc handoff_write_manifest {stage_paths args} {
  array set opt {
    -extra_kv {}
  }
  array set opt $args

  set manifest_out [handoff_get $stage_paths manifest_out]
  if {$manifest_out eq ""} {
    return
  }

  set record $stage_paths
  dict set record design $::DESIGN
  dict set record timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
  dict set record cwd [pwd]
  if {[llength $opt(-extra_kv)]} {
    foreach {key value} $opt(-extra_kv) {
      dict set record $key $value
    }
  }

  set fh [open $manifest_out w]
  puts $fh "# Unified Cadence handoff manifest"
  puts $fh "namespace eval ::handoff {}"
  puts $fh "set ::handoff::record [list $record]"
  close $fh
}

proc handoff_read_manifest {manifest_path} {
  if {![file exists $manifest_path]} {
    error "Missing handoff manifest: $manifest_path"
  }
  namespace eval ::handoff {}
  catch {unset ::handoff::record}
  uplevel #0 [list source $manifest_path]
  if {![info exists ::handoff::record]} {
    error "Manifest '$manifest_path' did not define ::handoff::record."
  }
  return $::handoff::record
}

proc handoff_write_stage_outputs {stage_paths args} {
  array set opt {
    -def_args {-floorplan}
    -write_def 1
    -write_v 1
    -copy_sdc 1
    -save_design 0
    -write_png 1
    -fit 1
    -write_manifest 1
    -extra_manifest {}
  }
  array set opt $args

  set def_out [handoff_get $stage_paths def_out]
  set v_out [handoff_get $stage_paths v_out]
  set sdc_in [handoff_get $stage_paths sdc_in]
  set sdc_out [handoff_get $stage_paths sdc_out]
  set enc_out [handoff_get $stage_paths enc_out]
  set png_out [handoff_get $stage_paths png_out]

  if {$opt(-write_def)} {
    if {$def_out eq ""} {
      error "Missing def_out for stage '[handoff_get $stage_paths stage]'."
    }
    defOut {*}$opt(-def_args) $def_out
  }
  if {$opt(-write_v)} {
    if {$v_out eq ""} {
      error "Missing v_out for stage '[handoff_get $stage_paths stage]'."
    }
    saveNetlist $v_out
  }
  if {$opt(-copy_sdc)} {
    handoff_copy_file_if_exists $sdc_in $sdc_out
  }

  foreach alias [handoff_get $stage_paths def_aliases {}] {
    handoff_copy_file_if_exists $def_out $alias
  }
  foreach alias [handoff_get $stage_paths v_aliases {}] {
    handoff_copy_file_if_exists $v_out $alias
  }
  foreach alias [handoff_get $stage_paths sdc_aliases {}] {
    if {$sdc_out ne ""} {
      handoff_copy_file_if_exists $sdc_out $alias
    } else {
      handoff_copy_file_if_exists $sdc_in $alias
    }
  }

  if {$opt(-save_design) && $enc_out ne ""} {
    saveDesign $enc_out
  }
  if {$opt(-fit)} {
    fit
  }
  if {$opt(-write_png) && $png_out ne ""} {
    catch {dumpToGIF $png_out}
  }
  if {$opt(-write_manifest)} {
    handoff_write_manifest $stage_paths -extra_kv $opt(-extra_manifest)
  }
}
