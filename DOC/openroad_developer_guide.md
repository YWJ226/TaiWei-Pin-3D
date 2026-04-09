# OpenROAD Developer Guide

## Scope

This guide is for developers who want to integrate a new OpenROAD Research C++ capability into this repository as a real staged flow command.

The intended workflow is:

1. add or expose a C++ command in OpenROAD Research
2. make that command callable from Tcl
3. wrap design database read/write in a stage Tcl script under `scripts_openroad/`
4. register the Tcl wrapper in the project `Makefile` as a new `ord-*` stage command
5. build a comparison flow variant using the stage ordering style shown in `test/openroad/README.sh`
6. compare the new flow against the original flow using a separate `FLOW_VARIANT`

The key rule is: do not patch the existing public flow in a way that prevents A/B comparison. Add a new stage or a new target first, then compare it to the baseline flow.

## Recommended Integration Pattern

### 1. Add the C++ feature in OpenROAD Research

Your algorithm should live in OpenROAD Research as a normal command implementation, not as a one-off shell script.

Recommended constraints:

- keep the command database-driven
- avoid hardcoding repo paths
- take parameters through Tcl arguments or environment variables
- operate on the currently loaded design database
- do not embed project-specific handoff filenames in C++

The repository-side Tcl wrapper should decide:

- which database to load
- which stage input files to use
- where the output handoff should be written
- which `FLOW_VARIANT` the run belongs to

That keeps the C++ side reusable and the project-side flow reproducible.

### 2. Expose the command to Tcl

The command must be callable from the OpenROAD Tcl shell. The repository flow is stage-script driven, so if the command is not visible in Tcl, it is not stage-integratable.

Typical expectation:

- a Tcl command name is exported by OpenROAD Research
- the command operates on the currently loaded database
- options are explicit and scriptable

Keep the Tcl surface minimal and stable. The stage wrapper should remain readable and should not need project-specific C++ knowledge.

## Repository-Side Stage Integration

### 1. Create a stage Tcl wrapper

Add a new script under `scripts_openroad/`, following the same structure used by the current staged flow.

Recommended front matter:

```tcl
# ============================================================
# my_stage.tcl
# Short description of what this stage does.
# ============================================================

# Core setup
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "my-stage"
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting my stage"

# Stage body
my_cpp_command -option_a foo -option_b bar

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_manifest 1 \
  -write_image 1
exit
```

For route-like or ODB-based stages, follow the corresponding database pattern already used in the flow instead of forcing everything through `DEF_IN`.

### 2. Reuse the handoff manager instead of inventing ad hoc file IO

The canonical file naming and manifest logic already lives in:

- [handoff_manager.tcl](scripts_openroad/handoff_manager.tcl)

Use it for:

- input/output file resolution
- stage aliases
- canonical handoff filenames
- manifest generation

This is important because the rest of the flow, GUI reopen helpers, and restart workflows already assume those handoff contracts.

### 3. Add the new stage to `handoff_manager.tcl`

If your stage produces a real handoff boundary, add a new stage entry to:

- [handoff_manager.tcl](scripts_openroad/handoff_manager.tcl)

Define:

- `stage_label`
- `def_in` / `v_in` / `sdc_in` or `odb_in`
- `def_out` / `v_out` / `sdc_out` or `odb_out`
- optional aliases
- optional summary/image paths

If the stage is only an in-place modifier, still define it explicitly so the manifest and GUI/open logic remain consistent.

## Makefile Integration

### 1. Add a new `ord-*` target

Register the Tcl wrapper in the OpenROAD section of:

- [Makefile](Makefile)

Follow the current stage-target style. A typical stage looks like:

```make
.PHONY: ord-my-stage
ord-my-stage:
	@$(call _mkstdirs)
	$(call _run_with_tmp_log,$(LOG_DIR)/X_Y_my_stage.log,LEF_FILES="$(LEF_FILES_SPLIT)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/my_stage.tcl)
```

Keep these conventions:

- use `_mkstdirs`
- use `_run_with_tmp_log`
- give the stage a stable `ord-*` name
- choose the correct `LEF_FILES*` view for the stage
- keep log naming consistent with neighboring stages

### 2. Prefer adding a new stage or a new experimental target

Do not overwrite the original public target immediately.

Prefer one of:

- `ord-my-stage`
- `ord-route-exp`
- `ord-cts-post-myalg`
- `ord-3d-flow-myalg`

This lets you compare:

- original target chain
- experimental target chain

under different `FLOW_VARIANT`s without losing the baseline.

## Database Read/Write Expectations

The repository-side Tcl script should own database lifecycle management.

Typical patterns:

- floorplan/place style stage:
  - `load_design $DEF_IN $SDC_IN ...`
  - call your Tcl/C++ command
  - `handoff_write_stage_outputs`

- route or post-route style stage:
  - restore/read the routed database as done by the existing route scripts
  - call your Tcl/C++ command
  - publish the correct handoff through `handoff_write_stage_outputs`

Do not make the C++ command read or write repository-specific handoff files by itself. Keep that logic in Tcl so the stage contract stays visible and reviewable.

## Building a New Flow for Comparison

Once the new `ord-*` stage exists, create a dedicated comparison flow rather than editing the baseline launcher in place.

The easiest pattern is to copy the stage-order style from:

- [test/openroad/README.sh](test/openroad/README.sh)

That file is useful because it documents each step with:

- input artifacts
- output artifacts
- stage ordering

Use it as the template for a new experimental launcher or test script.

Recommended options:

- create a new script under `test/openroad/`
- or create an experiment launcher under `experiment_scripts/`

Example approach:

1. copy the stage sequence comments from `test/openroad/README.sh`
2. insert your new stage where it belongs
3. set a new `FLOW_VARIANT`, for example `openroad_myalg`
4. run the same case once with baseline `openroad`
5. run the same case once with `openroad_myalg`
6. compare timing, DRC, split summaries, and final summaries

## Suggested A/B Method

Use a separate `FLOW_VARIANT` for the new flow.

Recommended naming:

- baseline: `openroad`
- experiment: `openroad_myalg`
- CI/regression: `ORD_CI`

Comparison commands can use:

- [test/common/run_stage.sh](test/common/run_stage.sh) for one-stage validation
- [test/common/run_case.sh](test/common/run_case.sh) for full-case validation
- [experiment_scripts/ORD_CI_REGRESSION.sh](experiment_scripts/ORD_CI_REGRESSION.sh) for pre-push OpenROAD regression

This gives you:

- the original flow
- the experimental flow
- a stable CI-style regression mode

without changing the meaning of the public baseline.

## Minimal Checklist

Before considering the new stage integrated, verify all of the following:

1. the C++ command is callable from OpenROAD Tcl
2. a dedicated Tcl stage wrapper exists under `scripts_openroad/`
3. `handoff_manager.tcl` knows the stage contract
4. `Makefile` exposes the stage as an `ord-*` target
5. the stage can be run standalone with `test/common/run_stage.sh`
6. the stage is inserted into a comparison flow with a separate `FLOW_VARIANT`
7. the new flow can be compared against the original flow on at least one small case and one macro case

## Common Mistakes

Avoid these:

- putting repo-specific path logic inside C++
- skipping the Tcl wrapper and calling the tool through shell glue only
- writing outputs directly without going through `handoff_write_stage_outputs`
- reusing the baseline `FLOW_VARIANT` for an experimental flow
- changing the public baseline target before proving A/B equivalence

## Recommended First Test

For a brand-new OpenROAD stage, start with:

- one small case such as `gcd` or `ibex`
- one macro case such as `swerv_wrapper`

Validate in this order:

1. standalone stage execution with `run_stage.sh`
2. full flow execution with a custom `FLOW_VARIANT`
3. summary comparison against the baseline flow
4. only then broaden to regression coverage
