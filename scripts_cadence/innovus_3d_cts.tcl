# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_cts.tcl
# Compatibility wrapper for staged CTS flow.
# The public Makefile targets now launch dedicated stage scripts directly.
# ============================================================

if {[info exists ::env(CTS_STAGE)] && $::env(CTS_STAGE) ne ""} {
  set cts_stage [string tolower $::env(CTS_STAGE)]
} else {
  set cts_stage "owner-tree"
}

switch -- $cts_stage {
  owner-tree -
  owner_tree {
    source $::env(CADENCE_SCRIPTS_DIR)/innovus_3d_cts_owner_tree.tcl
  }
  receive-opt -
  receive_opt {
    source $::env(CADENCE_SCRIPTS_DIR)/innovus_3d_cts_receive_opt.tcl
  }
  owner-mixed -
  owner_mixed -
  mixed {
    error "CTS_STAGE '$cts_stage' is deprecated after the split-net flow update. Use owner-tree / receive-opt / finalize."
  }
  finalize -
  finalize_only {
    source $::env(CADENCE_SCRIPTS_DIR)/innovus_3d_cts_finalize.tcl
  }
  default {
    error "Unsupported CTS_STAGE '$cts_stage'. Use owner-tree / receive-opt / finalize."
  }
}
