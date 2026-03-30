# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_route.tcl
# Compatibility wrapper for staged route/postRoute flow.
# The public Makefile targets now launch dedicated stage scripts directly.
# ============================================================

if {[info exists ::env(ROUTE_STAGE)] && $::env(ROUTE_STAGE) ne ""} {
  set route_stage [string tolower $::env(ROUTE_STAGE)]
} else {
  set route_stage "route-only"
}

switch -- $route_stage {
  route-only {
    source $::env(CADENCE_SCRIPTS_DIR)/innovus_3d_route_only.tcl
  }
  postroute-receive {
    source $::env(CADENCE_SCRIPTS_DIR)/innovus_3d_postroute_receive.tcl
  }
  postroute-owner {
    source $::env(CADENCE_SCRIPTS_DIR)/innovus_3d_postroute_owner.tcl
  }
  postroute-owner-mixed {
    error "ROUTE_STAGE '$route_stage' is deprecated after the split-net flow update. Use route-only / postroute-receive / postroute-owner."
  }
  default {
    error "Unsupported ROUTE_STAGE '$route_stage'. Use route-only / postroute-receive / postroute-owner."
  }
}
