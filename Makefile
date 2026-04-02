# =========================================
# Unified Pin3D Flow Makefile (ord-* / cds-*)
# - All targets are .PHONY and non-file, supports FLOW_VARIANT=hybrid
# - Logs are always written to a temporary file first, then atomically moved
#   to the final log path to avoid unbounded append growth
# =========================================

-include settings.mk

# ---------------- Common paths ----------------
export FLOW_HOME     ?= $(shell pwd)
export DESIGN_HOME   ?= $(FLOW_HOME)/designs
export PLATFORM_HOME ?= $(FLOW_HOME)/platforms
export WORK_HOME     ?= .

# Script directories
export OPENROAD_SCRIPTS_DIR ?= $(FLOW_HOME)/scripts_openroad
export CADENCE_SCRIPTS_DIR  ?= $(FLOW_HOME)/scripts_cadence
export UTILS_DIR            ?= $(FLOW_HOME)/util

# ---------------- Design config ----------------
# DESIGN_CONFIG ?= ./designs/nangate45_3D/gcd/config.mk
include $(DESIGN_CONFIG)

# ---------------- Platform names ----------------
export 2D_PLATFORM ?= $(PLATFORM)
export 3D_PLATFORM ?= $(PLATFORM)_3D
export 2D_PLATFORM_DIR ?= $(PLATFORM_HOME)/$(2D_PLATFORM)
export 3D_PLATFORM_DIR ?= $(PLATFORM_HOME)/$(3D_PLATFORM)

# ---------------- Platform resolve ----------------
# Resolve $(PLATFORM_DIR) from:
# (1) PLATFORM_HOME
# (2) local public platforms
# (3) ../../ fallback
PUBLIC_PLATFORMS = nangate45 nangate45_3D asap7 asap7_3D asap7_nangate45 asap7_nangate45_3D
ifneq ($(wildcard $(PLATFORM_HOME)/$(PLATFORM)),)
  export PLATFORM_DIR = $(PLATFORM_HOME)/$(PLATFORM)
else ifneq ($(findstring $(PLATFORM),$(PUBLIC_PLATFORMS)),)
  export PLATFORM_DIR = ./platforms/$(PLATFORM)
else ifneq ($(wildcard ../../$(PLATFORM)),)
  export PLATFORM_DIR = ../../$(PLATFORM)
else
  $(error [ERROR][FLOW] Platform '$(PLATFORM)' not found.)
endif

ifeq ($(MAKELEVEL),0)
$(info [INFO][FLOW] Using platform directory $(PLATFORM_DIR))
endif

include $(PLATFORM_DIR)/config.mk

# ---------------- Work dirs ----------------
export DESIGN_NICKNAME ?= $(DESIGN_NAME)
export FLOW_VARIANT    ?= base   # can be openroad / cadence / hybrid

export LOG_DIR     ?= $(WORK_HOME)/logs/$(PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)
export OBJECTS_DIR ?= $(WORK_HOME)/objects/$(PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)
export REPORTS_DIR ?= $(WORK_HOME)/reports/$(PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)
export RESULTS_DIR ?= $(WORK_HOME)/results/$(PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)

# ---------------- Shell / time ----------------
SHELL       := /usr/bin/env bash
.SHELLFLAGS := -o pipefail -c
TIME_CMD    = /usr/bin/time -f 'Elapsed: %E  CPU: user %U sys %S (%P)  Peak: %M KB'
TIME_TEST   = $(shell $(TIME_CMD) echo foo 2>/dev/null)
ifeq (, $(strip $(TIME_TEST)))
  TIME_CMD = /usr/bin/time
endif

# Detect CPU core count (portable fallbacks)
ifndef NUM_CORES
	NPROC := $(shell nproc 2>/dev/null)

	ifeq (, $(strip $(NPROC)))
		# Linux (generic)
		NPROC := $(shell grep -c ^processor /proc/cpuinfo 2>/dev/null)
	endif
	ifeq (, $(strip $(NPROC)))
		# BSD / macOS
		NPROC := $(shell sysctl -n hw.ncpu 2>/dev/null)
	endif
	ifeq (, $(strip $(NPROC)))
		# Fallback
		NPROC := 1
	endif
endif
export NUM_CORES

# ---------------- Tools ----------------
# OpenROAD toolchain
export OPENROAD_EXE ?= $(shell which openroad)
export YOSYS_EXE    ?= $(shell which yosys)
export STA_EXE      ?= $(shell which sta)
export PYTHON_EXE   ?= $(shell which python3)

OPENROAD_ARGS = -no_init -threads ${NUM_CORES} -exit
OPENROAD_CMD  = $(OPENROAD_EXE) $(OPENROAD_ARGS)
YOSYS_FLAGS  += -v 3

# Cadence toolchain
export GENUS_EXE   ?= $(shell which genus)
export INNOVUS_EXE ?= $(shell which innovus)

GENUS_CMD   = $(GENUS_EXE)
INNOVUS_CMD = $(INNOVUS_EXE) -64 -abort_on_error
export OPEN_GUI ?= 0
override OPENROAD_CMD = $(OPENROAD_EXE) $(OPENROAD_ARGS)

# ---------------- Helpers ----------------
define _mkstdirs
	mkdir -p $(RESULTS_DIR) $(LOG_DIR) $(REPORTS_DIR) $(OBJECTS_DIR)
endef

# Unified log runner:
# - write to a temporary log first
# - atomically replace the final log with mv
# - preserve the real command exit status under pipefail + tee
define _run_with_tmp_log
	@tmp_log="$(1).tmp"; \
	rm -f "$$tmp_log"; \
	{ $(2); } 2>&1 | tee "$$tmp_log"; \
	cmd_status=$${PIPESTATUS[0]}; \
	mv -f "$$tmp_log" "$(1)"; \
	exit $$cmd_status
endef

# Unified OpenROAD runner
define _or
$(call _run_with_tmp_log,$(2),$(TIME_CMD) $(OPENROAD_CMD) $(1))
endef

# Unified Cadence runner
define _cad
$(call _run_with_tmp_log,$(2),$(TIME_CMD) $(1))
endef

# ---------------- Library preprocessing ----------------
# Create temporary Liberty files with proper dont_use for Yosys/ABC.
# NOTE: ensure plain ASCII spaces here to avoid NBSP breaking variables.
override DONT_USE_LIBS := $(patsubst %.lib.gz, %.lib, $(addprefix $(OBJECTS_DIR)/lib/, $(notdir $(LIB_FILES))))
export DONT_USE_SC_LIB ?= $(firstword $(DONT_USE_LIBS))

# Fallbacks: if LIB_DIR / LEF_DIR are not provided by platform config, infer them safely.
export LIB_DIR ?= $(firstword $(sort $(dir $(LIB_FILES))))
export LEF_DIR ?= $(dir $(TECH_LEF))
ALLOW_NET_TAG := $(if $(strip $(TIER_ALLOW_NET)),.$(TIER_ALLOW_NET),)

.SECONDEXPANSION:
$(DONT_USE_LIBS): $$(filter %$$(@F) %$$(@F).gz,$(LIB_FILES))
	@mkdir -p $(OBJECTS_DIR)/lib
	$(UTILS_DIR)/preprocessLib.py -i $^ -o $@

$(OBJECTS_DIR)/lib/merged.lib:
	$(UTILS_DIR)/mergeLib.pl $(PLATFORM)_merged $(DONT_USE_LIBS) > $@

# ---------------- Design Flow Settings ----------------
export GALLERY_REPORT ?= 0

# Hierarchical Yosys
export SYNTH_HIERARCHICAL ?= 0
export SYNTH_STOP_MODULE_SCRIPT = $(OBJECTS_DIR)/mark_hier_stop_modules.tcl
ifeq ($(SYNTH_HIERARCHICAL), 1)
export HIER_REPORT_SCRIPT = $(OPENROAD_SCRIPTS_DIR)/synth_hier_report.tcl
export MAX_UNGROUP_SIZE ?= 0
endif

# Re-synthesis toggles
export RESYNTH_AREA_RECOVER ?= 0
export RESYNTH_TIMING_RECOVER ?= 0
export ABC_AREA ?= 0

# Global synthesis args
# export SYNTH_ARGS ?= -flatten

# Global floorplan args
export PLACE_PINS_ARGS

export GPL_TIMING_DRIVEN ?= 1
export GPL_ROUTABILITY_DRIVEN ?= 1

export ENABLE_DPO ?= 1
export DPO_MAX_DISPLACEMENT ?= 5 1

# Public CTS knobs. Keep this list short and documented.
export CTS_LAYER ?= bottom
export F2F_CTS_MODE ?= single_trunk_handoff
export F2F_CTS_HANDOFFS_PER_DOMAIN ?= 1
ifeq ($(CTS_LAYER),upper)
  export COVER_LAYER ?= bottom
else ifeq ($(CTS_LAYER),bottom)
  export COVER_LAYER ?= upper
endif

# 3D flow config consolidation:
# Keep only config2d.mk + config.mk, and derive cover LEF variants at runtime.
export OUTER_ITERATIONS ?= 1
export SKIP_2D_PART ?= 0
SC_LEF_UPPER_COVER ?= $(SC_LEF)
SC_LEF_BOTTOM_COVER ?= $(SC_LEF)
ADDITIONAL_LEFS_DEFAULT ?= $(ADDITIONAL_LEFS)
ADDITIONAL_LEFS_UPPER_COVER ?=
ADDITIONAL_LEFS_BOTTOM_COVER ?=
ADDITIONAL_LEFS_CTS ?=

LEF_FILES_UPPER_COVER ?= $(TECH_LEF) $(SC_LEF_UPPER_COVER) $(ADDITIONAL_LEFS_UPPER_COVER)
LEF_FILES_BOTTOM_COVER ?= $(TECH_LEF) $(SC_LEF_BOTTOM_COVER) $(ADDITIONAL_LEFS_BOTTOM_COVER)

ifeq ($(CTS_LAYER),upper)
	SC_LEF_CTS ?= $(SC_LEF_BOTTOM_COVER)
	LEF_FILES_CTS ?= $(TECH_LEF) $(SC_LEF_CTS) $(ADDITIONAL_LEFS_CTS) $(ADDITIONAL_LEFS_BOTTOM_COVER)
	LEF_FILES_NONE_CTS ?= $(LEF_FILES_UPPER_COVER)
else ifeq ($(CTS_LAYER),bottom)
	SC_LEF_CTS ?= $(SC_LEF_UPPER_COVER)
	LEF_FILES_CTS ?= $(TECH_LEF) $(SC_LEF_CTS) $(ADDITIONAL_LEFS_CTS) $(ADDITIONAL_LEFS_UPPER_COVER)
	LEF_FILES_NONE_CTS ?= $(LEF_FILES_BOTTOM_COVER)
else
	SC_LEF_CTS ?= $(SC_LEF)
	LEF_FILES_CTS ?= $(TECH_LEF) $(SC_LEF_CTS) $(ADDITIONAL_LEFS_CTS)
	LEF_FILES_NONE_CTS ?= $(LEF_FILES_UPPER_COVER)
endif

LEF_FILES_CTS_OWNER ?= $(LEF_FILES_CTS)
LEF_FILES_CTS_RECEIVE ?= $(LEF_FILES_NONE_CTS)
LEF_FILES_CTS_FINALIZE ?= $(LEF_FILES_NONE_CTS)
LEF_FILES_SPLIT ?= $(LEF_FILES)
LEF_FILES_ROUTE_ONLY ?= $(LEF_FILES)
LEF_FILES_ROUTE ?= $(LEF_FILES)
LEF_FILES_POSTROUTE_RECEIVE ?= $(LEF_FILES_NONE_CTS)
LEF_FILES_POSTROUTE_OWNER ?= $(LEF_FILES_CTS)

# =========================================
# ============ OpenROAD (ord-*) ===========
# =========================================
.PHONY: ord-versions
ord-versions:
	@$(call _mkstdirs)
	@{ $(YOSYS_EXE) -V; echo openroad $$($(OPENROAD_CMD) -version); } > $(LOG_DIR)/versions.txt 2>&1 || true

.PHONY: ord-2d_flow
ord-2d_flow:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/openroad_2d_flow.log,$(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/openroad_2d_flow.tcl)

# ---- Generate preprocessed Liberty explicitly ----
.PHONY: prep-libs
prep-libs:
	@$(call _mkstdirs)
	@echo "[ORD] Preprocess liberty -> $(OBJECTS_DIR)/lib/"
	@$(MAKE) --no-print-directory $(DONT_USE_LIBS)
	@# Explicitly build firstword as well (robustness against path aliasing)
	@$(MAKE) --no-print-directory $(DONT_USE_SC_LIB)

# ----- Synthesis (Yosys) with explicit environment passing -----
.PHONY: ord-synth
ord-synth: prep-libs
	@$(call _mkstdirs)
	@echo "[ORD] Synthesis (Yosys)"
	@echo "[ORD] Using libs: $(DONT_USE_LIBS)" > $(LOG_DIR)/1_0_synth_env.log
	$(call _run_with_tmp_log,$(LOG_DIR)/1_1_yosys.log,/usr/bin/env \
	  DONT_USE_LIBS="$(DONT_USE_LIBS)" \
	  DONT_USE_SC_LIB="$(DONT_USE_SC_LIB)" \
	  LIB_SYNTH="$(DONT_USE_LIBS)" \
	  LIB_FILES="$(LIB_FILES)" \
	  LIB_DIR="$(LIB_DIR)" \
	  LEF_DIR="$(LEF_DIR)" \
	  TECH_LEF="$(TECH_LEF)" \
	  SC_LEF="$(SC_LEF)" \
	  ADDITIONAL_LEFS="$(ADDITIONAL_LEFS)" \
	  VERILOG_FILES="$(VERILOG_FILES)" \
	  SDC_FILE="$(SDC_FILE)" \
	  DESIGN_NAME="$(DESIGN_NAME)" \
	  SYNTH_ARGS="$(SYNTH_ARGS)" \
	  ABC_AREA="$(ABC_AREA)" \
	  ADDER_MAP_FILE="$(ADDER_MAP_FILE)" \
	  LATCH_MAP_FILE="$(LATCH_MAP_FILE)" \
	  CLKGATE_MAP_FILE="$(CLKGATE_MAP_FILE)" \
	  MAX_UNGROUP_SIZE="$(MAX_UNGROUP_SIZE)" \
	  $(TIME_CMD) $(YOSYS_EXE) $(YOSYS_FLAGS) -c $(OPENROAD_SCRIPTS_DIR)/synth.tcl)
	@# Keep historical artifact names aligned
	@cp -f $(SDC_FILE) $(RESULTS_DIR)/1_synth.sdc 2>/dev/null || true

# ----- Floorplan / IO -----
.PHONY: ord-floorplan
ord-floorplan:
	@$(call _mkstdirs)
	@echo "[ORD] Floorplan"
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/floorplan.tcl,$(LOG_DIR)/2_1_floorplan.log)

.PHONY: ord-io
ord-io:
	@$(call _mkstdirs)
	@echo "[ORD] IO placement"
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/io_placement_random.tcl,$(LOG_DIR)/2_2_floorplan_io.log)

# ----- 2Dpre: synth + floorplan + IO + tier partition + copy to *_3D -----
.PHONY: ord-preplace
ord-preplace:
	@$(MAKE) --no-print-directory ord-floorplan
	@$(MAKE) --no-print-directory ord-io

.PHONY: ord-tier-partition
ord-tier-partition:
	@$(call _mkstdirs)
	@echo "[ORD] Tier partition"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_tritonpart.log,$(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/tier_partition.tcl)
	@echo "[ORD] Copy 2D artifacts to $(3D_PLATFORM)"
	@mkdir -p $(WORK_HOME)/results/$(3D_PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)
	@cp -rf $(RESULTS_DIR)/* $(WORK_HOME)/results/$(3D_PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)/ || true

.PHONY: ord-test-partition
ord-test-partition:
	@$(call _mkstdirs)
	@echo "[ORD] Tier partition"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_tritonpart.log,$(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/tier_partition_experiment.tcl)
	@echo "[ORD] Copy 2D artifacts to $(3D_PLATFORM)"
	@mkdir -p $(WORK_HOME)/results/$(3D_PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)
	@cp -rf $(RESULTS_DIR)/* $(WORK_HOME)/results/$(3D_PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)/ || true

# ----- 3D init -----
.PHONY: ord-pre
ord-pre:
	@$(call _mkstdirs)
	@echo "[ORD] Generate 3D views"
	@python3 "$(OPENROAD_SCRIPTS_DIR)/generate_3d_views.py" \
		--def-in    "$(RESULTS_DIR)/2_2_floorplan_io.def" \
		--v-in      "$(RESULTS_DIR)/2_2_floorplan_io.v" \
		--def-out   "$(RESULTS_DIR)/$(DESIGN_NAME)_3D.fp.def" \
		--v-out     "$(RESULTS_DIR)/$(DESIGN_NAME)_3D.fp.v" \
		--partition "$(RESULTS_DIR)/partition.txt" \
		--cell-map  "$(PLATFORM_DIR)/map.json"

# ----- Place -----
.PHONY: ord-place-init
ord-place-init:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_init.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/place_init.tcl)

.PHONY: ord-place-init-upper
ord-place-init-upper:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_init_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/place_init_upper.tcl)

.PHONY: ord-place-init-bottom
ord-place-init-bottom:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_init_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/place_init_bottom.tcl)

.PHONY: ord-place-upper
ord-place-upper:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/place_upper.tcl)

.PHONY: ord-place-bottom
ord-place-bottom:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/place_bottom.tcl)

.PHONY: ord-3d-floorplan
ord-3d-floorplan:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/2_3_floorplan_3d.log,LEF_FILES="$(LEF_FILES_SPLIT)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/floorplan_3d.tcl)

.PHONY: ord-3d-io
ord-3d-io:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/2_4_floorplan_io.log,LEF_FILES="$(LEF_FILES_SPLIT)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/io_place_3d.tcl)

.PHONY: ord-3d-split-net
ord-3d-split-net:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/2_4_floorplan_split.log,LEF_FILES="$(LEF_FILES_SPLIT)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/split_net_stage.tcl)

.PHONY: ord-place-macro-upper
ord-place-macro-upper:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/2_5_place_macro_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/place_macro_upper.tcl)

.PHONY: ord-place-macro-bottom
ord-place-macro-bottom:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/2_5_place_macro_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/place_macro_bottom.tcl)

.PHONY: ord-3d-pdn-only-bottom
ord-3d-pdn-only-bottom:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/2_6_floorplan_pdn_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/pdn_only_bottom.tcl)

.PHONY: ord-3d-pdn-only-upper
ord-3d-pdn-only-upper:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/2_6_floorplan_pdn_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/pdn_only_upper.tcl)

.PHONY: ord-3d-pdn-only
ord-3d-pdn-only:
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-3d-pdn-only-bottom
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-3d-pdn-only-upper

.PHONY: ord-3d-pdn
ord-3d-pdn:
	@$(call _mkstdirs)
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/pdn.tcl,$(LOG_DIR)/2_6_floorplan_pdn.log)
	@cp -f $(RESULTS_DIR)/1_synth.sdc $(RESULTS_DIR)/2_floorplan.sdc
	@cp -f $(RESULTS_DIR)/2_6_floorplan_pdn.def $(RESULTS_DIR)/2_floorplan.def
	@cp -f $(RESULTS_DIR)/2_6_floorplan_pdn.v   $(RESULTS_DIR)/2_floorplan.v

.PHONY: ord-re-3d-pdn
ord-re-3d-pdn:
	@$(call _mkstdirs)
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/re_pdn.tcl,$(LOG_DIR)/2_6_floorplan_pdn.log)
	@cp -f $(RESULTS_DIR)/1_synth.sdc $(RESULTS_DIR)/2_floorplan.sdc
	@cp -f $(RESULTS_DIR)/2_6_floorplan_pdn.def $(RESULTS_DIR)/2_floorplan.def
	@cp -f $(RESULTS_DIR)/2_6_floorplan_pdn.v   $(RESULTS_DIR)/2_floorplan.v

.PHONY: ord-pre_cts
ord-pre_cts:
	@$(call _mkstdirs)
	@# 1) def and v from global placement
	@cp -f $(RESULTS_DIR)/$(DESIGN_NAME)_3D.tmp.def $(RESULTS_DIR)/$(DESIGN_NAME)_3D.def
	@cp -f $(RESULTS_DIR)/$(DESIGN_NAME)_3D.tmp.v $(RESULTS_DIR)/$(DESIGN_NAME)_3D.v
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/global_placement_odb.tcl,$(LOG_DIR)/3_3_global_placement_odb.log)
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/resize.tcl,$(LOG_DIR)/3_4_place_resized.log)
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/detail_place.tcl,$(LOG_DIR)/3_5_place_dp.log)
	@cp -f $(RESULTS_DIR)/3_5_place_dp.odb $(RESULTS_DIR)/3_place.odb
	@cp -f $(RESULTS_DIR)/2_floorplan.sdc $(RESULTS_DIR)/3_place.sdc 2>/dev/null || true

.PHONY: ord-gp2lg
ord-gp2lg:
	@$(call _mkstdirs)
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/handoff_copy_gp2lg.tcl,$(LOG_DIR)/3_3_gp2lg.log)

.PHONY: ord-legalize-upper
ord-legalize-upper:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/3_5_lg_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/opt_lg_upper.tcl)

.PHONY: ord-legalize-bottom
ord-legalize-bottom:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/3_4_lg_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/opt_lg_bottom.tcl)

# ----- CTS / Route / Finish -----
.PHONY: ord-cts
ord-cts:
	@$(call _mkstdirs)
	@echo "[ORD] CTS"
	$(call _run_with_tmp_log,$(LOG_DIR)/4_0_cts.log,LEF_FILES="$(LEF_FILES_CTS)" COVER_LAYER="$(COVER_LAYER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/cts.tcl)

.PHONY: ord-cts-post
ord-cts-post:
	@$(call _mkstdirs)
	@echo "[ORD] CTS post"
	$(call _run_with_tmp_log,$(LOG_DIR)/4_1_cts_post.log,LEF_FILES="$(LEF_FILES_NONE_CTS)" COVER_LAYER="$(COVER_LAYER)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/cts_post.tcl)

.PHONY: ord-re-cts
ord-re-cts:
	@$(call _mkstdirs)
	@echo "[ORD] CTS"
	$(call _or,$(OPENROAD_SCRIPTS_DIR)/re-cts.tcl,$(LOG_DIR)/4_1_cts.log)

.PHONY: ord-route
ord-route:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/5_1_grt.log,LEF_FILES="$(LEF_FILES)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/global_route.tcl)
	$(call _run_with_tmp_log,$(LOG_DIR)/5_2_route.log,LEF_FILES="$(LEF_FILES)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/detail_route.tcl)

.PHONY: ord-final
ord-final:
	@$(call _mkstdirs)
	@echo "[ORD] final_report ..."
	$(call _run_with_tmp_log,$(LOG_DIR)/6_report.log,LEF_FILES="$(LEF_FILES)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/final_report.tcl)

.PHONY: ord-3d-flow-2dpart
ord-3d-flow-2dpart:
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-synth
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-preplace
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-tier-partition

.PHONY: ord-3d-flow
ord-3d-flow:
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-pre
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-3d-floorplan
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-3d-io
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-3d-split-net
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-place-macro-upper
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-place-macro-bottom
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-3d-pdn-only
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-place-init
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-place-init-upper
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-place-init-bottom
	@for i in $$(seq 1 $(OUTER_ITERATIONS)); do \
		echo "Iteration: $$i"; \
		$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-place-upper; \
		$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-place-bottom; \
	done
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-gp2lg
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-legalize-upper
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-legalize-bottom
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-cts
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-cts-post
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-route
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) ord-final

# ----- HotSpot -----
export FINAL_DEF ?= $(RESULTS_DIR)/6_final.def
export FINAL_V   ?= $(RESULTS_DIR)/6_final.v
export FINAL_SDC ?= $(RESULTS_DIR)/6_final.sdc
export FINAL_SPEF ?= $(RESULTS_DIR)/6_final.spef
export HOTSPOT_SCRIPTS_DIR ?= $(FLOW_HOME)/HotSpot
export MAX_T_PY         := $(HOTSPOT_SCRIPTS_DIR)/scripts/max_t.py
export DIVIDE_GRID_PY   := $(HOTSPOT_SCRIPTS_DIR)/scripts/divide_grid.py
export DIVIDE_DEF_PY    := $(HOTSPOT_SCRIPTS_DIR)/scripts/divide_def.py
export REPORT_POWER_TCL := $(HOTSPOT_SCRIPTS_DIR)/scripts/run_report_power.tcl
export MERGE_PTRACE_PY  := $(HOTSPOT_SCRIPTS_DIR)/scripts/merge_ptrace.py
export HOTSPOT_OUTPUT   := $(HOTSPOT_SCRIPTS_DIR)/scripts/output

.PHONY: ord-hotspot
ord-hotspot:
	@echo "[ORD] HotSpot"
	@echo "Starting HotSpot Thermal Analysis for design: $(DESIGN_NAME)"
	python3 $(DIVIDE_DEF_PY) -i $(FINAL_DEF) -o $(RESULTS_DIR)

	@echo "[1/8] Dividing upper DEF into grids..."
	python3 $(DIVIDE_GRID_PY) \
		-i "$(RESULTS_DIR)/6_final_upper.def" \
		-o "$(HOTSPOT_OUTPUT)" \
		-g 10 \
		--flp "floorplan1.flp" \
		--prefix "upper"

	@echo "[2/8] Running power analysis with STA for upper die..."
	LIB_FILES="$(SC_LIB_UPPER)" $(STA_EXE) $(REPORT_POWER_TCL)

	@mv "$(HOTSPOT_OUTPUT)/$(DESIGN_NAME).ptrace" "$(HOTSPOT_OUTPUT)/upper.ptrace"

	@echo "[3/8] Dividing bottom DEF into grids..."
	python3 $(DIVIDE_GRID_PY) \
		-i "$(RESULTS_DIR)/6_final_bottom.def" \
		-o "$(HOTSPOT_OUTPUT)" \
		-g 10 \
		--flp "floorplan2.flp" \
		--prefix "bottom"

	@echo "[4/8] Running power analysis with STA for bottom die..."
	LIB_FILES="$(SC_LIB_BOTTOM)" $(STA_EXE) $(REPORT_POWER_TCL)

	@mv "$(HOTSPOT_OUTPUT)/$(DESIGN_NAME).ptrace" "$(HOTSPOT_OUTPUT)/bottom.ptrace"

	python3 $(MERGE_PTRACE_PY) \
		-u "$(HOTSPOT_OUTPUT)/upper.ptrace" \
		-b "$(HOTSPOT_OUTPUT)/bottom.ptrace" \
		-o "$(HOTSPOT_OUTPUT)/test.ptrace"

	rm -f "$(HOTSPOT_OUTPUT)/upper.ptrace" "$(HOTSPOT_OUTPUT)/bottom.ptrace"

	@echo "[6/8] Creating version directory..."
	@mkdir -p "$(HOTSPOT_SCRIPTS_DIR)/examples/$(DESIGN_DIMENSION)_$(DESIGN_NAME)"
	@mkdir -p "$(HOTSPOT_SCRIPTS_DIR)/examples/thermal/"
	@chown -R $(USER):$(USER) "$(HOTSPOT_SCRIPTS_DIR)/examples/$(DESIGN_DIMENSION)_$(DESIGN_NAME)"

	@rsync -a --exclude='*/' \
		"$(HOTSPOT_SCRIPTS_DIR)/examples/thermal/" \
		"$(HOTSPOT_SCRIPTS_DIR)/examples/$(DESIGN_DIMENSION)_$(DESIGN_NAME)/"

	@cp -f "$(HOTSPOT_SCRIPTS_DIR)/scripts/output/"* \
		"$(HOTSPOT_SCRIPTS_DIR)/examples/$(DESIGN_DIMENSION)_$(DESIGN_NAME)/" 2>/dev/null || true

	@echo "Running HotSpot analysis..."
	@cd "$(HOTSPOT_SCRIPTS_DIR)/examples/$(DESIGN_DIMENSION)_$(DESIGN_NAME)/" && \
		chown -R $(USER):$(USER) ./ && \
		chmod +x run.sh && \
		./run.sh

	@mkdir -p "$(RESULTS_DIR)/hotspot_outputs"
	@rsync -a --delete \
		"$(HOTSPOT_SCRIPTS_DIR)/examples/$(DESIGN_DIMENSION)_$(DESIGN_NAME)/outputs/" \
		"$(RESULTS_DIR)/hotspot_outputs/" 2>/dev/null || true
	@chown -R $(USER):$(USER) "$(RESULTS_DIR)/hotspot_outputs"

	@rm -r "$(HOTSPOT_SCRIPTS_DIR)/examples/thermal/outputs" || true
	@mkdir -p "$(HOTSPOT_SCRIPTS_DIR)/examples/thermal/outputs"
	@chown -R $(USER):$(USER) "$(HOTSPOT_SCRIPTS_DIR)/examples/thermal/outputs"

	@echo "[8/8] Analysis completed. Results: $(RESULTS_DIR)/hotspot_outputs"

# =========================================
# ============== Cadence (cds-*) ==========
# =========================================
.PHONY: cds-synth
cds-synth:
	@$(call _mkstdirs)
	@echo "[CDS] Genus synthesis"
	$(call _run_with_tmp_log,$(LOG_DIR)/1_genus.log,$(TIME_CMD) $(GENUS_CMD) -overwrite -log $(LOG_DIR)/cadence_1_genus.log -f $(CADENCE_SCRIPTS_DIR)/run_genus.tcl)
	@cp -f $(SDC_FILE) $(RESULTS_DIR)/1_synth.sdc 2>/dev/null || true

.PHONY: cds-preplace
cds-preplace:
	@$(call _mkstdirs)
	@echo "[CDS] Innovus pre-place"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_innovus_preplace.log,$(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_2_innovus_preplace.log -files $(CADENCE_SCRIPTS_DIR)/innovus_preplace.tcl)

.PHONY: cds-2d_flow
cds-2d_flow:
	@$(call _mkstdirs)
	@echo "[CDS] Innovus 2D flow"
	$(call _run_with_tmp_log,$(LOG_DIR)/innovus_2d_flow.log,$(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_2d_flow.log -files $(CADENCE_SCRIPTS_DIR)/innovus_2d_flow.tcl)

.PHONY: cds-3d-flow-2dpart
cds-3d-flow-2dpart:
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) cds-synth
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) cds-preplace
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) cds-tier-partition

.PHONY: cds-tier-partition
cds-tier-partition:
	@$(call _mkstdirs)
	@echo "[CDS] Tier partition (OpenROAD in Cadence flow)"
	@echo "[CDS] Copying 2D artifacts to $(3D_PLATFORM) directory"
	@{ \
	  NEW_RESULTS_DIR="$(WORK_HOME)/results/$(3D_PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)"; \
	  mkdir -p "$$NEW_RESULTS_DIR"; \
	  cp -rf "$(RESULTS_DIR)"/* "$$NEW_RESULTS_DIR"; \
	  echo "[CDS] Running TritonPart locally..."; \
	  export RESULTS_DIR="$$NEW_RESULTS_DIR"; \
	  tmp_log="$(LOG_DIR)/2_tritonpart.log.tmp"; \
	  rm -f "$$tmp_log"; \
	  { $(TIME_CMD) $(OPENROAD_CMD) $(CADENCE_SCRIPTS_DIR)/tritonpart_tier_partition.tcl; } 2>&1 | tee "$$tmp_log"; \
	  cmd_status=$${PIPESTATUS[0]}; \
	  mv -f "$$tmp_log" "$(LOG_DIR)/2_tritonpart.log"; \
	  exit $$cmd_status; \
	}

.PHONY: cds-pre
cds-pre:
	@$(call _mkstdirs)
	@echo "[CDS] Generate 3D views"
	@python3 "$(CADENCE_SCRIPTS_DIR)/generate_3d_views.py" \
		--def-in    "$(RESULTS_DIR)/2_2_floorplan_io.def" \
		--v-in      "$(RESULTS_DIR)/2_2_floorplan_io.v" \
		--def-out   "$(RESULTS_DIR)/$(DESIGN_NAME)_3D.fp.def" \
		--v-out     "$(RESULTS_DIR)/$(DESIGN_NAME)_3D.fp.v" \
		--partition "$(RESULTS_DIR)/partition.txt" \
		--cell-map  "$(PLATFORM_DIR)/map.json"

.PHONY: cds-3d-pdn
cds-3d-pdn:
	@$(call _mkstdirs)
	@echo "[CDS] 3D PDN"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_pdn.log,$(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_pdn.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_pdn.tcl)

.PHONY: cds-3d-floorplan
cds-3d-floorplan:
	@$(call _mkstdirs)
	@echo "[CDS] 3D floorplan"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_3_floorplan_3d.log,$(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_2_3_floorplan_3d.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_floorplan.tcl)

.PHONY: cds-3d-io
cds-3d-io:
	@$(call _mkstdirs)
	@echo "[CDS] 3D IO placement"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_4_floorplan_io.log,$(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_2_4_floorplan_io.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_io_place.tcl)

.PHONY: cds-3d-split-net
cds-3d-split-net:
	@$(call _mkstdirs)
	@echo "[CDS] 3D mixed-tier split net"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_4_floorplan_split.log,LEF_FILES="$(LEF_FILES_SPLIT)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_2_4_floorplan_split.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_split_net.tcl)

.PHONY: cds-place-macro-upper
cds-place-macro-upper:
	@$(call _mkstdirs)
	@echo "[CDS] Macro placement upper"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_5_place_macro_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_2_5_place_macro_upper.log -files $(CADENCE_SCRIPTS_DIR)/innovus_placeMacro_upper.tcl)

.PHONY: cds-place-macro-bottom
cds-place-macro-bottom:
	@$(call _mkstdirs)
	@echo "[CDS] Macro placement bottom"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_5_place_macro_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_2_5_place_macro_bottom.log -files $(CADENCE_SCRIPTS_DIR)/innovus_placeMacro_bottom.tcl)

.PHONY: cds-3d-pdn-only
cds-3d-pdn-only:
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) cds-3d-pdn-only-bottom
	@$(MAKE) --no-print-directory DESIGN_CONFIG=$(DESIGN_CONFIG) cds-3d-pdn-only-upper

.PHONY: cds-3d-pdn-only-bottom
cds-3d-pdn-only-bottom:
	@$(call _mkstdirs)
	@echo "[CDS] 3D PDN only bottom"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_6_floorplan_pdn_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_2_6_floorplan_pdn_bottom.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_pdn-only-bottom.tcl)

.PHONY: cds-3d-pdn-only-upper
cds-3d-pdn-only-upper:
	@$(call _mkstdirs)
	@echo "[CDS] 3D PDN only upper"
	$(call _run_with_tmp_log,$(LOG_DIR)/2_6_floorplan_pdn_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_2_6_floorplan_pdn_upper.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_pdn-only-upper.tcl)

.PHONY: cds-place-init
cds-place-init:
	@$(call _mkstdirs)
	@echo "[CDS] Place init"
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_init.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_place_init.log -files $(CADENCE_SCRIPTS_DIR)/innovus_place3D_init.tcl)

.PHONY: cds-place-init-upper
cds-place-init-upper:
	@$(call _mkstdirs)
	@echo "[CDS] Place init upper"
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_init_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_place_init_upper.log -files $(CADENCE_SCRIPTS_DIR)/innovus_place3D_init_upper.tcl)

.PHONY: cds-place-init-bottom
cds-place-init-bottom:
	@$(call _mkstdirs)
	@echo "[CDS] Place init bottom"
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_init_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_place_init_bottom.log -files $(CADENCE_SCRIPTS_DIR)/innovus_place3D_init_bottom.tcl)

.PHONY: cds-place-upper
cds-place-upper:
	@$(call _mkstdirs)
	@echo "[CDS] Loop preCTS opt upper (allow net: $${TIER_ALLOW_NET:-all})"
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_upper$(ALLOW_NET_TAG).log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_place_upper$(ALLOW_NET_TAG).log -files $(CADENCE_SCRIPTS_DIR)/innovus_place3D_upper.tcl)

.PHONY: cds-place-bottom
cds-place-bottom:
	@$(call _mkstdirs)
	@echo "[CDS] Loop preCTS opt bottom (allow net: $${TIER_ALLOW_NET:-all})"
	$(call _run_with_tmp_log,$(LOG_DIR)/3_place_bottom$(ALLOW_NET_TAG).log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_place_bottom$(ALLOW_NET_TAG).log -files $(CADENCE_SCRIPTS_DIR)/innovus_place3D_bottom.tcl)

.PHONY: cds-gp2lg
cds-gp2lg:
	@$(call _mkstdirs)
	@echo "[CDS] GP2LG handoff copy"
	@tclsh "$(CADENCE_SCRIPTS_DIR)/handoff_copy_gp2lg.tcl"

.PHONY: cds-legalize-upper
cds-legalize-upper:
	@$(call _mkstdirs)
	@echo "[CDS] Legalize upper"
	$(call _run_with_tmp_log,$(LOG_DIR)/3_5_lg_upper.log,LEF_FILES="$(LEF_FILES_BOTTOM_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_opt_lg_upper.log -files $(CADENCE_SCRIPTS_DIR)/innovus_opt_lg_upper.tcl)

.PHONY: cds-legalize-bottom
cds-legalize-bottom:
	@$(call _mkstdirs)
	@echo "[CDS] Legalize bottom"
	$(call _run_with_tmp_log,$(LOG_DIR)/3_4_lg_bottom.log,LEF_FILES="$(LEF_FILES_UPPER_COVER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_opt_lg_bottom.log -files $(CADENCE_SCRIPTS_DIR)/innovus_opt_lg_bottom.tcl)

.PHONY: cds-cts
cds-cts:
	@$(call _mkstdirs)
	@echo "[CDS] CTS (owner-tree -> receive-opt -> finalize)"
	@$(MAKE) --no-print-directory DESIGN_CONFIG="$(DESIGN_CONFIG)" cds-cts-owner-tree
	@$(MAKE) --no-print-directory DESIGN_CONFIG="$(DESIGN_CONFIG)" cds-cts-receive-opt
	@$(MAKE) --no-print-directory DESIGN_CONFIG="$(DESIGN_CONFIG)" cds-cts-finalize
	@cat $(LOG_DIR)/4_0_cts_owner_tree.log $(LOG_DIR)/4_1_cts_receive_opt.log $(LOG_DIR)/4_3_cts_finalize.log > $(LOG_DIR)/4_1_cts.log
	@cat $(LOG_DIR)/cadence_innovus_3d_cts_owner_tree.log $(LOG_DIR)/cadence_innovus_3d_cts_receive_opt.log $(LOG_DIR)/cadence_innovus_3d_cts_finalize.log > $(LOG_DIR)/cadence_innovus_3d_cts.log

# Explicit legacy CTS target for robustness comparison.
.PHONY: cds-cts-legacy
cds-cts-legacy:
	@$(call _mkstdirs)
	@echo "[CDS] Legacy CTS"
	$(call _run_with_tmp_log,$(LOG_DIR)/4_1_cts.log,SC_FILE="$(SC_LEF_CTS)" SC_LEF="$(SC_LEF_CTS)" LEF_FILES="$(LEF_FILES_CTS)" ADDITIONAL_LEFS="$(ADDITIONAL_LEFS_CTS)" COVER_LAYER="$(COVER_LAYER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_cts.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_cts_legacy.tcl)

# Internal staged CTS targets. The public interface should stay cds-cts.
.PHONY: cds-cts-owner-tree
cds-cts-owner-tree:
	@$(call _mkstdirs)
	@echo "[CDS] CTS owner-tree (LEF/COVER: LEF_FILES_CTS_OWNER)"
	$(call _run_with_tmp_log,$(LOG_DIR)/4_0_cts_owner_tree.log,LEF_FILES="$(LEF_FILES_CTS_OWNER)" COVER_LAYER="$(COVER_LAYER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_cts_owner_tree.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_cts_owner_tree.tcl)

.PHONY: cds-cts-receive-opt
cds-cts-receive-opt:
	@$(call _mkstdirs)
	@echo "[CDS] CTS receive-opt (LEF/COVER: LEF_FILES_CTS_RECEIVE)"
	$(call _run_with_tmp_log,$(LOG_DIR)/4_1_cts_receive_opt.log,LEF_FILES="$(LEF_FILES_CTS_RECEIVE)" COVER_LAYER="$(COVER_LAYER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_cts_receive_opt.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_cts_receive_opt.tcl)

.PHONY: cds-cts-finalize
cds-cts-finalize:
	@$(call _mkstdirs)
	@echo "[CDS] CTS finalize (LEF/COVER: LEF_FILES_CTS_FINALIZE)"
	$(call _run_with_tmp_log,$(LOG_DIR)/4_3_cts_finalize.log,LEF_FILES="$(LEF_FILES_CTS_FINALIZE)" COVER_LAYER="$(COVER_LAYER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_cts_finalize.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_cts_finalize.tcl)

.PHONY: cds-route-new
cds-route-new:
	@$(call _mkstdirs)
	@echo "[CDS] Route (route-only -> postroute-receive -> postroute-owner)"
	@$(MAKE) --no-print-directory DESIGN_CONFIG="$(DESIGN_CONFIG)" cds-route-only
	@$(MAKE) --no-print-directory DESIGN_CONFIG="$(DESIGN_CONFIG)" cds-postroute-receive
	@$(MAKE) --no-print-directory DESIGN_CONFIG="$(DESIGN_CONFIG)" cds-postroute-owner
	@cat $(LOG_DIR)/5_0_route.log $(LOG_DIR)/5_1_postroute_receive.log $(LOG_DIR)/5_2_postroute_owner.log > $(LOG_DIR)/5_route.log
	@cat $(LOG_DIR)/cadence_innovus_3d_route_only.log $(LOG_DIR)/cadence_innovus_3d_postroute_receive.log $(LOG_DIR)/cadence_innovus_3d_postroute_owner.log > $(LOG_DIR)/cadence_innovus_3d_route.log

# Explicit legacy route target for robustness comparison.
.PHONY: cds-route
cds-route:
	@$(call _mkstdirs)
	@echo "[CDS] Legacy route"
	$(call _run_with_tmp_log,$(LOG_DIR)/5_route.log,LEF_FILES="$(LEF_FILES_ROUTE)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_route.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_route_legacy.tcl)

# Internal staged route targets. The public interface should stay cds-route.
.PHONY: cds-route-only
cds-route-only:
	@$(call _mkstdirs)
	@echo "[CDS] Route only (LEF/COVER: LEF_FILES_ROUTE_ONLY)"
	$(call _run_with_tmp_log,$(LOG_DIR)/5_0_route.log,LEF_FILES="$(LEF_FILES_ROUTE_ONLY)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_route_only.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_route_only.tcl)

.PHONY: cds-postroute-receive
cds-postroute-receive:
	@$(call _mkstdirs)
	@echo "[CDS] PostRoute receive (LEF/COVER: LEF_FILES_POSTROUTE_RECEIVE)"
	$(call _run_with_tmp_log,$(LOG_DIR)/5_1_postroute_receive.log,LEF_FILES="$(LEF_FILES_POSTROUTE_RECEIVE)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_postroute_receive.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_postroute_receive.tcl)

.PHONY: cds-postroute-owner
cds-postroute-owner:
	@$(call _mkstdirs)
	@echo "[CDS] PostRoute owner (LEF/COVER: LEF_FILES_POSTROUTE_OWNER)"
	$(call _run_with_tmp_log,$(LOG_DIR)/5_2_postroute_owner.log,LEF_FILES="$(LEF_FILES_POSTROUTE_OWNER)" $(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_postroute_owner.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_postroute_owner.tcl)

.PHONY: cds-final
cds-final:
	@$(call _mkstdirs)
	@echo "[CDS] Final"
	$(call _run_with_tmp_log,$(LOG_DIR)/6_final.log,$(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_final.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_final.tcl)

.PHONY: cds-restore
cds-restore:
	@$(call _mkstdirs)
	@echo "[CDS] Restore"
	$(call _run_with_tmp_log,$(LOG_DIR)/6_final-re.log,$(TIME_CMD) $(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_final-re.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_final-re.tcl)

.PHONY: clean_all
clean_all:
	@echo "[ORD] Cleaning results, logs, objects, reports for $(DESIGN_NAME) on $(PLATFORM)/$(FLOW_VARIANT)"
	@rm -rf $(RESULTS_DIR) $(LOG_DIR) $(OBJECTS_DIR) $(REPORTS_DIR)

# -------- HotSpot (reuse the OpenROAD variables) --------
.PHONY: cds-hotspot
cds-hotspot: ord-hotspot

# Default target
.DEFAULT_GOAL := ord-versions
