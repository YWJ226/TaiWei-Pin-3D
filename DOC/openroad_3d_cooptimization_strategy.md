# OpenROAD 3D Co-Optimization Strategy

## Scope

This document describes the current OpenROAD 3D commercial-style flow implemented in this repository. It is intentionally code-aligned:

- public flow targets come from [Makefile](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/Makefile)
- stage handoff contracts come from [handoff_manager.tcl](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/scripts_openroad/handoff_manager.tcl)
- tier and allow-net policy come from [placement_utils.tcl](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/scripts_openroad/placement_utils.tcl)
- launchers come from [test/openroad/ORD_3D_NEW_FLOW.sh](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/test/openroad/ORD_3D_NEW_FLOW.sh) and [test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh)

The goal is to make the OpenROAD flow structurally parallel to the Cadence flow:

- explicit stage-by-stage handoff management
- explicit split-net stage
- explicit allow-net / dont-touch-net tier policy
- staged preCTS optimization
- split summary and final summary generation

## Public Flow Entry

The OpenROAD launcher is:

- [ORD_3D_NEW_FLOW.sh](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/test/openroad/ORD_3D_NEW_FLOW.sh)

It accepts:

- `enablement`
- `flow_variant`
- `use_flow=openroad`
- `design_nickname`

Important environment switches:

- `PIN3D_ALLOW_NET_FLOW=on|off`
- `PIN3D_SPLIT_NET_FLOW=on|off`
- `TIER_ALLOW_NET=upper-only|bottom-only|all`
- `REUSE_2DPART_FROM_VARIANT=<variant>`
- `START_FROM=<stage>`
- `OUTER_ITERATIONS=<N>`

The default 3D stage order is:

```text
ord-pre
ord-3d-floorplan
ord-3d-io
ord-3d-split-net
ord-place-macro-upper
ord-place-macro-bottom
ord-3d-pdn-only
  -> ord-3d-pdn-only-bottom
  -> ord-3d-pdn-only-upper
ord-place-init
ord-place-init-upper
ord-place-init-bottom
OUTER_ITERATIONS times:
  ord-place-upper
  ord-place-bottom
ord-gp2lg
ord-legalize-upper
ord-legalize-bottom
ord-cts
ord-cts-post
ord-route
ord-final
```

`ord-3d-flow-2dpart` remains the 2D bootstrap wrapper:

- `ord-synth`
- `ord-preplace`
- `ord-tier-partition`

## Handoff Management

OpenROAD stage handoffs are centralized in:

- [handoff_manager.tcl](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/scripts_openroad/handoff_manager.tcl)

Each rebuilt stage follows the same front-matter structure:

1. `# Core setup`
2. `# Environment directories`
3. `# Stage handoff`
4. `# Additional setup`

Each rebuilt stage:

- resolves input/output files with `handoff_stage_paths`
- binds canonical stage variables with `handoff_bind_stage_io`
- logs the resolved files with `handoff_log_paths`
- writes outputs with `handoff_write_stage_outputs`
- writes a manifest under `results/.../handoffs/<stage>.tcl`

Canonical OpenROAD 3D handoff sequence:

| Stage | Input | Output |
|---|---|---|
| `ord-3d-floorplan` | `${DESIGN}_3D.fp.v`, `1_synth.sdc` | `2_3_floorplan_3d.def/.v`, `1_synth.sdc` |
| `ord-3d-io` | `2_3_floorplan_3d.def/.v`, `1_synth.sdc` | `2_4_floorplan_io.def/.v`, `1_synth.sdc` |
| `ord-3d-split-net` | `2_4_floorplan_io.def/.v`, `1_synth.sdc` | updated `2_4_floorplan_io.def/.v`, `1_synth.sdc` |
| `ord-place-macro-upper` | `2_4_floorplan_io.def/.v`, `1_synth.sdc` | `2_5_place_macro_upper.def/.v`, `1_synth.sdc` |
| `ord-place-macro-bottom` | `2_5_place_macro_upper.def/.v`, `1_synth.sdc` | `2_5_place_macro_bottom.def/.v`, `1_synth.sdc` |
| `ord-3d-pdn-only-bottom` | `2_5_place_macro_bottom.def/.v`, `1_synth.sdc` | `2_6_floorplan_pdn_bottom.def/.v`, `1_synth.sdc` |
| `ord-3d-pdn-only-upper` | `2_6_floorplan_pdn_bottom.def/.v`, `1_synth.sdc` | `2_6_floorplan_pdn.def/.v`, alias `2_floorplan.def/.v/.sdc` |
| `ord-place-init` | `2_floorplan.def/.v/.sdc` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` |
| `ord-place-init-upper` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | same handoff updated in place |
| `ord-place-init-bottom` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | same handoff updated in place |
| `ord-place-upper` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | same handoff updated in place |
| `ord-place-bottom` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | same handoff updated in place |
| `ord-gp2lg` | `${DESIGN}_3D.tmp.def/.v`, `2_floorplan.sdc` | `${DESIGN}_3D.lg.def/.v`, `2_floorplan.sdc` |
| `ord-legalize-upper` | `${DESIGN}_3D.lg.def/.v`, `2_floorplan.sdc` | same handoff updated in place, alias `3_place.def/.v/.sdc` |
| `ord-legalize-bottom` | `${DESIGN}_3D.lg.def/.v`, `2_floorplan.sdc` | same handoff updated in place, alias `3_place.def/.v/.sdc` |
| `ord-cts` | `3_place.def/.v/.sdc` | `4_0_cts.def/.v/.sdc/.odb` |
| `ord-cts-post` | `4_0_cts.def/.v/.sdc/.odb` | `4_cts.def/.v/.sdc/.odb` |
| `ord-route` | `4_cts.def/.v/.sdc` | `5_1_grt.odb/.sdc` then `5_route.def/.v/.sdc/.odb` |
| `ord-final` | `5_route.def/.v/.sdc` | `6_final.odb/.def/.v/.sdc`, `final_summary.txt` |

## LEF View Strategy

The OpenROAD Makefile uses the same LEF-view concept as the Cadence flow.

| LEF view | Meaning |
|---|---|
| `LEF_FILES_SPLIT` | Full 3D LEF visibility for front-end 3D construction and split-net |
| `LEF_FILES_BOTTOM_COVER` | Bottom tier is protected; upper tier is the active optimization side |
| `LEF_FILES_UPPER_COVER` | Upper tier is protected; bottom tier is the active optimization side |
| `LEF_FILES_NONE_CTS` | Non-owner CTS view used for post-CTS repair |
| `LEF_FILES` | Full LEF visibility for route and final report |

Applied by stage:

| Target | LEF view |
|---|---|
| `ord-3d-floorplan` | `LEF_FILES_SPLIT` |
| `ord-3d-io` | `LEF_FILES_SPLIT` |
| `ord-3d-split-net` | `LEF_FILES_SPLIT` |
| `ord-place-macro-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-macro-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-3d-pdn-only-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-3d-pdn-only-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-init` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-init-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-init-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-place-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-place-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-gp2lg` | handoff copy only |
| `ord-legalize-upper` | `LEF_FILES_BOTTOM_COVER` |
| `ord-legalize-bottom` | `LEF_FILES_UPPER_COVER` |
| `ord-cts` | `LEF_FILES_CTS` |
| `ord-cts-post` | `LEF_FILES_NONE_CTS` |
| `ord-route` | `LEF_FILES` |
| `ord-final` | `LEF_FILES` |

## Tier Strategy and Allow-Net Control

The OpenROAD tier policy is implemented in:

- [placement_utils.tcl](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/scripts_openroad/placement_utils.tcl)

It provides:

- instance-level `set_dont_touch` by master pattern
- library-side `set_dont_use`
- per-net `set_dont_touch` / `unset_dont_touch`
- requested vs effective allow-net resolution

### Net optimization classes

OpenROAD nets are classified into:

- `upper_only`
- `bottom_only`
- `mixed`
- `unknown`

The public knobs are:

- `PIN3D_ALLOW_NET_FLOW=on|off`
- `TIER_ALLOW_NET=upper-only|bottom-only|all`

Resolution rule:

- `PIN3D_ALLOW_NET_FLOW=off` forces effective allow-net to `all`
- otherwise `TIER_ALLOW_NET` is honored

Meaning:

- `upper-only`: unlock `upper_only` and `mixed`, lock `bottom_only` and `unknown`
- `bottom-only`: unlock `bottom_only` and `mixed`, lock `upper_only` and `unknown`
- `all`: unlock `upper_only`, `bottom_only`, and `mixed`, lock `unknown`

### Stage-level policy

| Target family | Tier policy |
|---|---|
| macro / PDN / route / final | `allow_net all` |
| `ord-place-upper` | `upper-only` |
| `ord-place-bottom` | `bottom-only` |
| `ord-legalize-upper` | `upper-only` |
| `ord-legalize-bottom` | `bottom-only` |
| `ord-cts` | owner-tier-only, derived from `CTS_LAYER` |
| `ord-cts-post` | opposite-tier-only, derived from `CTS_LAYER` |

`apply_tier_policy` rebuilds rows by default after switching tier context. This is now the intended behavior for OpenROAD 3D stages, including macro placement, split PDN, CTS, route, and final reporting, because follow-pin rails and tier-site consistency depend on the rebuilt row pattern.

## Split-Net Strategy

Split-net is now a real public stage:

- `ord-3d-split-net`
- script: [split_net_stage.tcl](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/scripts_openroad/split_net_stage.tcl)
- algorithm helper: [split_net.tcl](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/scripts_openroad/split_net.tcl)

Behavior:

- input and output are both `2_4_floorplan_io.def/.v`
- the stage edits the post-IO handoff in place
- `PIN3D_SPLIT_NET_FLOW=off` converts the stage into pass-through mode

Reports:

- `split_net.summary.rpt`
- `split_net.actions.rpt`
- `split_net.before.nets`
- `split_net.after.nets`

Current v1 scope:

- splitter insertion is reused from the existing OpenROAD helper
- top-level term driven nets are still skipped and reported as `top_level_term_net_not_supported`
- reporting terminology is normalized to `upper` / `bottom`

## Stage-by-Stage Target Map

| Target | Main script | Main commands | Purpose |
|---|---|---|---|
| `ord-pre` | `generate_3d_views.py` | view rewrite from partition + map | Create 3D DEF/netlist view from 2D preplace result |
| `ord-3d-floorplan` | `floorplan_3d.tcl` | `initialize_floorplan`, `make_tracks` | Build the initial 3D floorplan from the split netlist view |
| `ord-3d-io` | `io_place_3d.tcl` -> `io_place.tcl` | `set_io_pin_constraint`, `place_pins` | Deterministic perimeter IO placement |
| `ord-3d-split-net` | `split_net_stage.tcl` | `extract_cross_tier_nets`, `::tier_split_or2::run` | Reduce upper/bottom mixed-tier nets before macro placement |
| `ord-place-macro-upper` | `place_macro_upper.tcl` | `apply_tier_policy upper`, macro placement helper | Place upper macros while bottom tier is cover |
| `ord-place-macro-bottom` | `place_macro_bottom.tcl` | `apply_tier_policy bottom`, macro placement helper | Place bottom macros while upper tier is cover |
| `ord-3d-pdn-only-bottom` | `pdn_only_bottom.tcl` | handoff preservation + tier policy | Publish a bottom-side PDN checkpoint handoff |
| `ord-3d-pdn-only-upper` | `pdn_only_upper.tcl` | `pdngen`, `POST_PDN_TCL` | Final PDN pass and publish canonical `2_floorplan.*` |
| `ord-place-init` | `place_init.tcl` | `global_placement` | Bootstrap global placement on the 3D floorplan |
| `ord-place-init-upper` | `place_init_upper.tcl` | `global_placement` | Upper-focused init refinement |
| `ord-place-init-bottom` | `place_init_bottom.tcl` | `global_placement` | Bottom-focused init refinement |
| `ord-place-upper` | `place_upper.tcl` | `fastroute_setup`, `global_placement` | Upper tier preCTS optimization loop |
| `ord-place-bottom` | `place_bottom.tcl` | `fastroute_setup`, `global_placement` | Bottom tier preCTS optimization loop |
| `ord-gp2lg` | `handoff_copy_gp2lg.tcl` | handoff copy only | Freeze the staged tmp handoff into the legalize handoff |
| `ord-legalize-upper` | `opt_lg_upper.tcl` | `detailed_placement`, `opt_design` helper | Upper-side legalization and preCTS clean-up |
| `ord-legalize-bottom` | `opt_lg_bottom.tcl` | `detailed_placement`, `opt_design` helper | Bottom-side legalization and preCTS clean-up |
| `ord-cts` | `cts.tcl` | `repair_clock_inverters`, `clock_tree_synthesis`, `repair_clock_nets`, `repair_timing_helper` | Build clocks on the owner tier and repair timing |
| `ord-cts-post` | `cts_post.tcl` | `repair_clock_nets`, `repair_timing_helper` | Opposite-tier post-CTS timing repair |
| `ord-route` | `global_route.tcl`, `detail_route.tcl` | `global_route`, `detailed_route`, `repair_timing_helper` | Route the design and preserve `5_route.sdc` |
| `ord-final` | `final_report.tcl` | `global_connect`, `deleteRoutingObstructions`, `report_metrics`, `report_wire_length` | Publish `6_final.*` and final summary |

## Optimization Strategy

The OpenROAD co-optimization strategy currently has four main layers.

### 1. Structural co-optimization through staged handoff

The flow no longer jumps directly from `ord-pre` into a monolithic placement/routing path. Instead it carries explicit 3D handoffs through:

- 3D floorplan
- deterministic IO
- split-net
- macro placement
- PDN
- staged preCTS placement
- CTS and post-CTS repair
- route and final report

This makes each stage restartable and debuggable.

### 2. Tier-aware optimization masking

The flow now mirrors Cadence-style allow-net control:

- active side is optimized
- opposite side remains protected
- `mixed` nets stay optimizable in upper-only or bottom-only mode
- unknown nets stay locked even in `all`

This keeps optimization pressure focused while preserving cross-tier structure.

### 3. PreCTS split reduction

`ord-3d-split-net` runs before macro placement and before the staged placement loop. The intent is to reduce expensive upper/bottom mixed nets early, so later:

- global placement sees fewer unavoidable cross-tier interactions
- tier-local optimization has a cleaner signal graph
- the comparison against `PIN3D_SPLIT_NET_FLOW=off` is explicit and measurable

### 4. CTS and post-CTS repair

OpenROAD now uses a two-step clock/timing strategy:

- `ord-cts` builds the clock tree on the owner tier
- `ord-cts-post` repairs timing from the opposite-tier perspective

This mirrors the “owner then receive/fix” idea from the Cadence flow without yet splitting the public API into three separate OpenROAD CTS targets.

## Test and Experiment Scripts

OpenROAD test entry points under `test/openroad`:

- [ORD_3D_NEW_FLOW.sh](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/test/openroad/ORD_3D_NEW_FLOW.sh)
- [ORD_3D_ALLOW_NET_MATRIX.sh](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/test/openroad/ORD_3D_ALLOW_NET_MATRIX.sh)
- [ORD_3D_EXTRACT_VALID_SUMMARIES.sh](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/test/openroad/ORD_3D_EXTRACT_VALID_SUMMARIES.sh)
- [README.sh](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/test/openroad/README.sh)

The default matrix currently targets `gcd` first:

- `asap7_3D:gcd`
- `asap7_nangate45_3D:gcd`
- `nangate45_3D:gcd`

with the two comparison modes:

- `allownet:on:on`
- `noallownet:off:off`

The extractor writes CSV rows from:

- `split_net.summary.rpt`
- `final_summary.txt`

## Current Boundaries

This first rebuilt OpenROAD flow intentionally does not yet do everything the Cadence flow does.

Current boundaries:

- CTS and route remain public `ord-cts`, `ord-cts-post`, `ord-route` targets
- HB-via metrics are not added to the OpenROAD CSV yet
- top-level term-driven split-net support is still out of scope in v1
- the new IO logic mirrors the Cadence structure, but remains constrained by OpenROAD `set_io_pin_constraint` / `place_pins`

That said, the major flow architecture is now parallel to the commercial Cadence flow:

- same public stage shape
- same handoff discipline
- same allow-net and split-flow switches
- same staged preCTS philosophy
- same launcher and extraction pattern
