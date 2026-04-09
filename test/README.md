# Test Script Guide

This directory contains the stable entry points for running, rerunning, evaluating, and inspecting 3D flow test cases.

Use these scripts as the public interface. Strategy documents under `DOC/` should describe behavior and architecture, but should not embed ad hoc runtime-artifact paths.

## Common Wrappers

### Run one full case

- `test/common/run_case.sh <ord|cds> <case_dir>`

Examples:

```bash
bash test/common/run_case.sh ord test/asap7_3D/ibex/ord
bash test/common/run_case.sh cds test/asap7_3D/ibex/cds
```

What it does:

- resolves the repo root from the case directory
- selects the correct launcher
- forwards `FLOW_VARIANT`, `USE_FLOW`, and other flow environment variables

### Run one stage only

- `test/common/run_stage.sh <enablement> <flow_variant> <use_flow> <design_nickname> <make_target>`

Examples:

```bash
bash test/common/run_stage.sh asap7_3D ORD_CI openroad ibex ord-route
bash test/common/run_stage.sh asap7_3D cadence cadence ibex cds-route
```

Use this when:

- reproducing a bug at a single stage
- rerunning `cts`, `route`, `final`, or `restore` without launching the whole flow
- validating a local Tcl change quickly

### Run evaluation only

- `test/common/eval_case.sh <ord|cds> <case_dir>`

Examples:

```bash
bash test/common/eval_case.sh ord test/asap7_3D/ibex/ord
bash test/common/eval_case.sh cds test/asap7_3D/ibex/cds
```

Behavior:

- `ord` evaluation runs `cds-final`
- `cds` evaluation runs `cds-restore`

## OpenROAD Entry Points

### Full 3D OpenROAD flow

- `test/openroad/ORD_3D_NEW_FLOW.sh <enablement> <flow_variant> <use_flow> <design_nickname>`

Examples:

```bash
bash test/openroad/ORD_3D_NEW_FLOW.sh asap7_3D ORD_CI openroad ibex
bash test/openroad/ORD_3D_NEW_FLOW.sh nangate45_3D debug_variant openroad swerv_wrapper
```

Useful environment variables:

- `NUM_CORES`
- `OUTER_ITERATIONS`
- `PIN3D_ALLOW_NET_FLOW`
- `PIN3D_SPLIT_NET_FLOW`
- `SKIP_2D_PART`
- `REUSE_2DPART_FROM_VARIANT`
- `START_FROM`

### Allow-net comparison matrix

- `test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh`

Use this when comparing:

- allow-net on vs off
- split-net on vs off
- matrix-style OpenROAD experiments on the same design

### OpenROAD GUI reopen

- `test/openroad/ORD_3D_OPEN_GUI.sh <enablement> <flow_variant> <design_nickname> <stage-or-manifest>`

Examples:

```bash
bash test/openroad/ORD_3D_OPEN_GUI.sh asap7_3D ORD_CI ibex ord-route
bash test/openroad/ORD_3D_OPEN_GUI.sh asap7_3D ORD_CI ibex results/asap7_3D/ibex/ORD_CI/handoffs/route.tcl
```

Use this to reopen a stage handoff in the OpenROAD GUI.

## Cadence Entry Points

### Full 3D Cadence flow

- `test/commercial/CDS_3D_NEW_FLOW.sh <enablement> <flow_variant> <use_flow> <design_nickname>`

Examples:

```bash
bash test/commercial/CDS_3D_NEW_FLOW.sh asap7_3D cadence cadence ibex
bash test/commercial/CDS_3D_NEW_FLOW.sh asap7_nangate45_3D cadence_debug cadence swerv_wrapper
```

Useful environment variables mirror the OpenROAD launcher:

- `NUM_CORES`
- `OUTER_ITERATIONS`
- `PIN3D_ALLOW_NET_FLOW`
- `PIN3D_SPLIT_NET_FLOW`
- `SKIP_2D_PART`
- `START_FROM`

### Allow-net comparison matrix

- `test/commercial/CDS_3D_ALLOW_NET_MATRIX.sh`

Use this when running Cadence allow-net / split-flow comparisons on the same design.

### Cadence GUI reopen

- `test/commercial/CDS_3D_OPEN_GUI.sh <enablement> <flow_variant> <design_nickname> <stage-or-manifest>`

Examples:

```bash
bash test/commercial/CDS_3D_OPEN_GUI.sh asap7_3D cadence ibex cds-route
bash test/commercial/CDS_3D_OPEN_GUI.sh asap7_3D cadence ibex route-legacy
```

Use this to reopen a staged Cadence handoff in Innovus GUI.

## Per-Case Wrappers

Each design directory also contains tiny per-case wrappers such as:

- `test/asap7_3D/ibex/ord/run.sh`
- `test/asap7_3D/ibex/cds/run.sh`

These are convenient when:

- you already know the exact case directory
- you want a short command that plugs into `run_case.sh`
- you want to keep CI or regression scripts compact

## Example Workflows

### Fresh OpenROAD run

```bash
FLOW_VARIANT=ORD_CI bash test/asap7_3D/ibex/ord/run.sh
```

### Resume one OpenROAD stage

```bash
bash test/common/run_stage.sh asap7_3D ORD_CI openroad ibex ord-cts-post
```

### Fresh Cadence run

```bash
FLOW_VARIANT=cadence bash test/asap7_3D/ibex/cds/run.sh
```

### Re-extract final metrics only

```bash
bash test/common/run_stage.sh asap7_3D cadence cadence ibex cds-restore
```
