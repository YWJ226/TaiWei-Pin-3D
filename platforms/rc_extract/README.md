# RC Rule Extraction from 3D LEF Using Patterns + OpenRCX

This directory contains a three-step RC calibration flow:

1. generate pattern benches from a unified 3D tech LEF with OpenROAD/OpenRCX
2. extract parasitics for those patterns with Innovus
3. fit OpenRCX pattern rules from the extracted SPEF

The purpose is to turn a unified 3D LEF stack into an OpenRCX `.rules` file that can later be used by OpenROAD for parasitic extraction.

## Core idea

- Treat the heterogeneous 3D stack as one unified routing stack in LEF.
- Use OpenRCX pattern benches to sample representative wires across layers.
- Use a commercial extractor to produce a golden SPEF for those patterns.
- Use OpenRCX to fit RC rules from pattern geometry plus golden SPEF.

## Execution model

This flow now runs directly from the repository workspace.

Current expectation:

- `OPENROAD_BIN` and `CDS_BIN` are both available in the shell where you launch the scripts
- `FLOW_VARIANT` selects the input LEF and the per-variant work/output directories
- all three steps see the same local workspace paths

## Directory layout

Under `platforms/rc_extract/`:

```text
rc_extract/
  env.sh

  01_gen_patterns.sh
  02_cds_extract.sh
  03_gen_rules.sh

  flow.sh

  script/
    01_gen_patterns.tcl
    02_cds_extract.tcl
    03_ord_gen_rules.tcl

  input/
    <FLOW_VARIANT>.lef

  work/
    <FLOW_VARIANT>/
      patterns.def
      patterns.v
      cds/
        patterns.spef
      ord/
        extRules
      log/
        01_gen_patterns.log
        02_cds_extract.log
        03_gen_rules.log

  output/
    <FLOW_VARIANT>.rcx_patterns.rules
```

## Environment

`env.sh` is the central entry point.

It defines:

- tool binaries
- Tcl script paths
- selected `FLOW_VARIANT`
- per-variant input LEF path
- per-variant work/output paths

Typical usage:

```bash
cd platforms/rc_extract
export FLOW_VARIANT=asap7_nangate45_2A6M10M
source env.sh
```

or:

```bash
cd platforms/rc_extract
source env.sh asap7_nangate45_2A6M10M
```

Main variables:

```bash
export OPENROAD_BIN=...
export CDS_BIN=$(which innovus)
export NUM_CORES=16
export CDS_RC_SETUP_TCL=""

export TECH_LEF="$PROJ_ROOT/input/${FLOW_VARIANT}.lef"
export WORK_DIR="$PROJ_ROOT/work/$FLOW_VARIANT"
export CDS_OUT_DIR="$WORK_DIR/cds"
export ORD_OUT_DIR="$WORK_DIR/ord"
export LOG_DIR="$WORK_DIR/log"

export PATTERN_DEF="$WORK_DIR/patterns.def"
export PATTERN_V="$WORK_DIR/patterns.v"
export PATTERN_SPEF="$CDS_OUT_DIR/patterns.spef"
export RCX_RULES="$PROJ_ROOT/output/${FLOW_VARIANT}.rcx_patterns.rules"
```

## Standard workflow

Run the three steps in order:

```bash
cd platforms/rc_extract
source env.sh <FLOW_VARIANT>

./01_gen_patterns.sh
./02_cds_extract.sh
./03_gen_rules.sh
```

This is the canonical flow.

### Optional multi-variant launcher

`flow.sh` is a convenience wrapper that runs several predefined `FLOW_VARIANT`s in parallel. It is not required for normal use.

Use it as:

```bash
cd platforms/rc_extract
bash flow.sh
```

## Step 1: Generate pattern benches

Script:

- [01_gen_patterns.sh](01_gen_patterns.sh)

Tcl:

- [01_gen_patterns.tcl](script/01_gen_patterns.tcl)

Purpose:

- read the selected unified 3D LEF
- generate RC pattern benches with OpenRCX
- write `patterns.def` and `patterns.v`

Important outputs:

- `work/<FLOW_VARIANT>/patterns.def`
- `work/<FLOW_VARIANT>/patterns.v`

Key command:

```bash
"${OPENROAD_BIN}" -threads $NUM_CORES "${TCL_GEN_PATTERNS}"
```

## Step 2: Extract RC with Innovus

Script:

- [02_cds_extract.sh](02_cds_extract.sh)

Tcl:

- [02_cds_extract.tcl](script/02_cds_extract.tcl)

Purpose:

- read the selected LEF plus generated pattern DEF
- optionally read the generated Verilog
- run commercial extraction
- write a golden SPEF

Important output:

- `work/<FLOW_VARIANT>/cds/patterns.spef`

Key command:

```bash
"${CDS_BIN}" -64 -overwrite -no_gui -init "${TCL_CDS_EXTRACT}" -log "${LOG_FILE}"
```

Today this uses Innovus internal LEF/emulated RC. A future `CDS_RC_SETUP_TCL` can switch the same step to a signoff RC setup.

## Step 3: Fit OpenRCX rules

Script:

- [03_gen_rules.sh](03_gen_rules.sh)

Tcl:

- [03_ord_gen_rules.tcl](script/03_ord_gen_rules.tcl)

Purpose:

- read the unified LEF
- read the generated pattern DEF
- read the golden SPEF
- fit OpenRCX pattern rules
- write the final `.rules` file

Important output:

- `output/<FLOW_VARIANT>.rcx_patterns.rules`

Key command:

```bash
"${OPENROAD_BIN}" -threads $NUM_CORES "${TCL_GEN_RULES}"
```

The shell wrapper currently moves `work/<FLOW_VARIANT>/ord/extRules` to the final `output/<FLOW_VARIANT>.rcx_patterns.rules` path.

## Conceptual data flow

```text
unified 3D LEF
  -> OpenRCX bench generation
  -> patterns.def + patterns.v
  -> Innovus extraction
  -> patterns.spef
  -> OpenRCX rule fitting
  -> <FLOW_VARIANT>.rcx_patterns.rules
```

## Why the flow is split into three steps

This separation makes it easy to:

- debug pattern generation independently
- swap the commercial extractor later if needed
- rerun only the expensive extraction step
- compare different LEF stacks under the same extraction flow

## Notes and limitations

- The current extraction path is LEF/emulated RC, not signoff QRC.
- `FLOW_VARIANT` naming must match the LEF filename under `input/`.
- `flow.sh` is only a convenience launcher; the three individual step scripts are the stable interface.
- This directory is a calibration utility, not part of the main `ord-*` or `cds-*` staged implementation flow.
