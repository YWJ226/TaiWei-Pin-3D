# Cadence 3D Co-Optimization Strategy

## DOC

This flow is intentionally not built around one monolithic Tcl script. The optimization result comes from three coordinated mechanisms:

1. Constraints decide which tier, net class, or clock scope is allowed to move in the current phase.
2. LEF and COVER view selection decide which physical implementation options are visible to Innovus in that phase.
3. Tcl stage scripts execute one phase of the flow and write an explicit checkpoint for the next phase.

The main objective is to minimize additional cross-tier nets while still using a largely 2D tool interface to approximate 3D co-optimization. The flow therefore favors staged optimization, explicit checkpoints, and view switching over a single aggressive optimization loop.

The important implication is that `apply_tier_policy` is not the optimizer. It is a constraint setter. The actual result depends on the combination of:

- `Makefile` stage orchestration
- shell wrapper sequencing in `test.swerv_wrapper_run/*.sh`
- LEF/COVER view selection
- tier and net-class constraints
- Innovus commands executed in each phase

### LEF and COVER View Strategy

The Makefile controls phase visibility through view-specific variables:

- `LEF_FILES_UPPER_COVER`
- `LEF_FILES_BOTTOM_COVER`
- `LEF_FILES_CTS_OWNER`
- `LEF_FILES_CTS_RECEIVE`
- `LEF_FILES_CTS_MIXED`
- `LEF_FILES_CTS_FINALIZE`
- `LEF_FILES_ROUTE_ONLY`
- `LEF_FILES_POSTROUTE_RECEIVE`
- `LEF_FILES_POSTROUTE_OWNER`
- `LEF_FILES_POSTROUTE_MIXED`
- `CTS_LAYER`
- `COVER_LAYER`

These variables are part of the optimization strategy, not just file plumbing.

- `allow_net` limits which net class is eligible for optimization in a given pass.
- COVER-specific LEF files limit which cells and physical views are available in that pass.
- CTS-specific LEF files expose the owner-tier implementation view selected by `CTS_LAYER`.
- route and postRoute stages use different LEF selections so wiring realization and RC-aware ECO are kept separate.

This is how the flow approximates 3D optimization using a 2D-oriented tool interface.

The Makefile already demonstrates this pattern in the existing upper and bottom optimization targets. When a tier is optimized, the flow loads the LEF view associated with that tier's COVER strategy. This helps avoid false overlap handling between COVER cells and CORE cells, but it is still not sufficient by itself.

Even when the active LEF view prevents COVER and CORE cells from being treated as ordinary overlaps, the placer may still move COVER cells unless they are explicitly fixed. For that reason, LEF/COVER view switching and explicit placement fixing are both required:

- view switching controls what Innovus can legally see and optimize
- `set_tier_placement_status ... fixed` prevents the placer from drifting COVER cells during incremental optimization

The flow should therefore treat COVER fixing as a mandatory constraint layer on top of view selection, not as an optional refinement.

### How To Read The Flow

Read the flow in this order:

1. `Makefile`
2. `test.swerv_wrapper_run/*.sh`
3. `scripts_cadence/*.tcl`

The Makefile defines stage boundaries and view selection. The shell wrappers define the outer loop. The Tcl scripts implement one phase at a time.

## CTS

### Goal

CTS is modeled as a semantic staged flow driven by `CTS_LAYER`:

- `owner-tree`: build the owner-tier clock tree on `CTS_LAYER`
- `receive-opt`: optimize receive-tier-only nets on the opposite tier
- `owner-mixed`: optimize mixed-only nets with the owner tier active
- `finalize`: freeze the clock topology before route and postRoute

This avoids treating CTS as one opaque 3D optimization step and reduces zig-zag buffering patterns such as `Aupper -> Bufferbottom -> Cupper`.

### Stages

The public target remains `cds-cts`, but it orchestrates four internal stages:

1. `cds-cts-owner-tree`
2. `cds-cts-receive-opt`
3. `cds-cts-owner-mixed`
4. `cds-cts-finalize`

The compatibility wrapper is `scripts_cadence/innovus_3d_cts.tcl`, but the public Makefile targets launch dedicated stage scripts directly. Shared logic lives in `scripts_cadence/cts_stage_common.tcl`.

### Stage Semantics

`cds-cts-owner-tree`

- LEF view: `LEF_FILES_CTS_OWNER`
- active tier: `CTS_LAYER`
- fixed tier: the opposite tier
- `allow_net`: derived internally as `upper-only` or `bottom-only`
- main commands:
  - `apply_tier_policy <owner_tier> -fixlib 1 -allow_net <owner_only>`
  - clear `dont_touch` from all clock nets after the net-class mask is applied
  - `create_ccopt_clock_tree_spec`
  - `ccopt_design`
- outputs:
  - `4_0_cts_owner_tree.{def,v,sdc}`
  - `cts_owner_tree.before.nets`
  - `cts_owner_tree.after.nets`

`cds-cts-receive-opt`

- LEF view: `LEF_FILES_CTS_RECEIVE`
- active tier: non-`CTS_LAYER`
- fixed tier: `CTS_LAYER`
- `allow_net`: derived internally as the opposite tier's `upper-only` or `bottom-only`
- main commands:
  - `apply_tier_policy <receive_tier> -fixlib 1 -allow_net <receive_only>`
  - freeze all clock nets
  - `optDesign -postCTS -incr`
- outputs:
  - `4_1_cts_receive_opt.{def,v,sdc}`
  - `cts_receive_opt.before.nets`
  - `cts_receive_opt.after.nets`

`cds-cts-owner-mixed`

- LEF view: `LEF_FILES_CTS_MIXED`
- active tier: `CTS_LAYER`
- fixed tier: the opposite tier
- `allow_net`: `mixed-only`
- main commands:
  - `apply_tier_policy <owner_tier> -fixlib 1 -allow_net mixed-only`
  - freeze all clock nets
  - `optDesign -postCTS -incr`
- outputs:
  - `4_2_cts_owner_mixed.{def,v,sdc}`
  - `cts_owner_mixed.before.nets`
  - `cts_owner_mixed.after.nets`

`cds-cts-finalize`

- LEF view: `LEF_FILES_CTS_FINALIZE`
- no optimization command is run here
- main commands:
  - freeze all clock nets
  - write final `4_cts.{def,v,sdc}`
- outputs:
  - `4_3_cts_finalize.{def,v,sdc}`
  - `4_cts.{def,v,sdc}`
  - `cts_finalize.nets`

### Reporting

CTS stages emit clock-only cross-tier reports:

- `cts_owner_tree.before.nets`
- `cts_owner_tree.after.nets`
- `cts_receive_opt.before.nets`
- `cts_receive_opt.after.nets`
- `cts_owner_mixed.before.nets`
- `cts_owner_mixed.after.nets`
- `cts_finalize.nets`

These reports are intended to make clock-related cross-tier changes attributable to a specific phase.

## Route

### Goal

Route and postRoute optimization must remain separate phases.

- `routeDesign` is responsible for realizing wires.
- `optDesign -postRoute` is responsible for RC-aware repair and ECO.

Treating them as a single stage makes it harder to see when extra cross-tier nets are introduced and which LEF/COVER view caused the change.

### Stages

The public target remains `cds-route`, but it orchestrates:

1. `cds-route-only`
2. `cds-postroute-receive`
3. `cds-postroute-owner`
4. `cds-postroute-owner-mixed`

`cds-route-only`

- LEF view: `LEF_FILES_ROUTE_ONLY`
- performs pure routing
- writes `5_0_route.{def,v,sdc}`
- emits before and after cross-tier reports

`cds-postroute-receive`

- LEF view: `LEF_FILES_POSTROUTE_RECEIVE`
- active tier: non-`CTS_LAYER`
- fixed tier: `CTS_LAYER`
- `allow_net`: receive-tier-only
- keeps the clock tree frozen
- runs `optDesign -postRoute`
- emits before and after cross-tier reports

`cds-postroute-owner`

- LEF view: `LEF_FILES_POSTROUTE_OWNER`
- active tier: `CTS_LAYER`
- fixed tier: non-`CTS_LAYER`
- `allow_net`: owner-tier-only
- keeps the clock tree frozen
- runs `optDesign -postRoute`
- emits before and after cross-tier reports

`cds-postroute-owner-mixed`

- LEF view: `LEF_FILES_POSTROUTE_MIXED`
- active tier: `CTS_LAYER`
- fixed tier: non-`CTS_LAYER`
- `allow_net`: `mixed-only`
- keeps the clock tree frozen
- runs `optDesign -postRoute`
- emits before and after cross-tier reports
- writes the final `5_route.{def,v,sdc}`

### Expected Outcome

The route split is not meant to guarantee that no new cross-tier nets appear. It is meant to make those additions visible, attributable, and easier to constrain away in future iterations.

## Local Development Harness

The flow also includes a local engineering work area under `work.codex/cts_route_lab/`.

This area is intentionally outside the public flow interface. It is used to:

- run syntax and target checks
- replay one stage at a time
- compare cross-tier reports between stages
- iterate on Tcl changes without rerunning the entire full flow

The recommended workflow is:

1. edit one Tcl stage
2. run the matching smoke script
3. inspect logs and cross-tier reports
4. move to the next stage only after the current stage interface is stable

## Robustness Validation with gcd and aes

The staged flow must be validated against a legacy baseline under a deliberately tighter clock. The validation objective is not only to complete the run, but also to show that the staged flow does not inflate additional cross-tier nets while still enabling useful timing repair with a 2D-oriented implementation tool.

### Validation Matrix

The current validation matrix uses three seed cases:

- `nangate45_3D / aes`
- `nangate45_3D / gcd`
- `asap7_3D / gcd`

Each case is run twice:

- `baseline`
- `staged`

The execution order is fixed to get quick feedback first:

1. `nangate45_3D / aes`
2. `nangate45_3D / gcd`
3. `asap7_3D / gcd`

### Tight-Clock Method

The robustness test uses a single tight-clock mode:

- `tight07`

The copied SDC for a validation variant is patched by scaling:

- `clk_period_new = clk_period_original * 0.7`

Only the `set clk_period ...` assignment is changed. The remaining SDC content, including `clk_io_pct`, is preserved.

### Seed and Variant Preparation

Validation starts from an existing floorplan checkpoint rather than rerunning synthesis and partition.

For each validation variant:

- copy the required seed checkpoint into a dedicated `FLOW_VARIANT`
- preserve the original `*_3D.fp.{def,v}` artifacts when available
- prepare downstream-compatible files:
  - `1_synth.sdc`
  - `2_floorplan.sdc`
  - `2_floorplan.def`
  - `2_floorplan.v`

This keeps the flow simple and reproducible while avoiding expensive front-end reruns.

### Strategy Definitions

`baseline`

- one upper preCTS optimization pass with `allow_net=all`
- one bottom preCTS optimization pass with `allow_net=all`
- final legalize on both tiers
- legacy monolithic CTS
- legacy monolithic route plus postRoute

`staged`

- `upper-only`
- `bottom-only`
- `mixed-only` on upper
- `mixed-only` on bottom
- final legalize on both tiers
- staged `owner-tree -> receive-opt -> owner-mixed -> finalize` CTS
- staged `route-only -> postroute-receive -> postroute-owner -> postroute-owner-mixed`

### Metrics

The validation harness records one row per `{case, strategy, stage}` and tracks:

- `WNS`
- `TNS`
- total DRV count
- buffer delta between stage input and stage output netlists
- total cross-tier nets before and after the stage
- clock-only cross-tier nets before and after CTS or route-related stages
- routing overflow
- normalized congestion hotspot area

Buffer delta is computed from explicit stage netlist snapshots. This is why the flow writes stable before and after netlists for the loop placement stages and final legalize stages.

### Acceptance Logic

The staged flow is considered healthier than the legacy baseline only if all of the following are true:

- the run completes through `cds-restore`
- stage metrics are present
- final staged cross-tier net count does not exceed the final legacy cross-tier net count for the same case
- clock-only cross-tier net count does not increase after `cts_finalize`

Timing and congestion are comparison metrics rather than single hard pass/fail gates. If the staged flow regresses either of them, the validation report must record that regression explicitly.
