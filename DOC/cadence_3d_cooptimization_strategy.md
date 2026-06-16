# Cadence 3D Commercial Flow and Co-Optimization Strategy

## 1. Scope

This document describes the current commercial 3D flow implemented in the Cadence branch of this repository. It is not a conceptual note only. It is meant to be a code-aligned reference for:

- how the flow is launched today
- which `make` targets exist
- which Tcl or Python script each target runs
- the exact stage input and output handoff files
- which LEF view is loaded at each stage
- what tier strategy each stage uses
- which main tool commands are executed
- how the optimization strategy is implemented across the whole flow

The authoritative sources are:

- [Makefile](Makefile)
- [test/commercial/CDS_3D_NEW_FLOW.sh](test/commercial/CDS_3D_NEW_FLOW.sh)
- [scripts_cadence/handoff_manager.tcl](scripts_cadence/handoff_manager.tcl)

## 2. How The Current Commercial Flow Runs

### 2.1 Public launchers

The current commercial flow is normally driven by:

- [CDS_3D_NEW_FLOW.sh](test/commercial/CDS_3D_NEW_FLOW.sh)
- [CDS_3D_ALLOW_NET_MATRIX.sh](test/commercial/CDS_3D_ALLOW_NET_MATRIX.sh)

`CDS_3D_NEW_FLOW.sh` is the single-run launcher. `CDS_3D_ALLOW_NET_MATRIX.sh` wrap it for comparison experiments.

### 2.2 Default target sequence

The current commercial launcher runs the following path by default:

```text
clean_all
cds-3d-flow-2dpart
  -> cds-synth
  -> cds-preplace
  -> cds-tier-partition
cds-pre
cds-3d-floorplan
cds-3d-io
cds-3d-split-net
cds-place-macro-upper
cds-place-macro-bottom
cds-3d-pdn-only
  -> cds-3d-pdn-only-bottom
  -> cds-3d-pdn-only-upper
cds-place-init
cds-place-init-upper
cds-place-init-bottom
OUTER_ITERATIONS times:
  cds-place-upper
  cds-place-bottom
cds-gp2lg
cds-legalize-upper
cds-legalize-bottom
cds-cts
  -> cds-cts-owner-tree
  -> cds-cts-receive-opt
  -> cds-cts-finalize
cds-route
cds-restore
```

Default targets used by the launcher:

- CTS: `cds-cts`
- Route: `cds-route`
- Final report: `cds-restore`

### 2.3 Resume and reuse behavior

The launcher also supports:

- `REUSE_2DPART_FROM_VARIANT=<variant>`
  - copy `1_synth.sdc`, `2_2_floorplan_io.def`, `2_2_floorplan_io.v`, and partition artifacts from an existing variant
  - then continue from `cds-pre`
- `START_FROM=<stage>`
  - resume from a later physical stage without rerunning earlier ones

This is why the physical stage contracts must be explicit and stable.

## 3. Core Flow Architecture

### 3.1 Handoff management

The canonical stage contracts are defined in:

- [handoff_manager.tcl](scripts_cadence/handoff_manager.tcl)

For each stage, `handoff_stage_paths` resolves:

- `def_in`, `v_in`, `sdc_in`, `enc_in`
- `def_out`, `v_out`, `sdc_out`, `enc_out`
- aliases such as `2_floorplan.def`, `3_place.def`, `4_cts.def`, `5_route.def`
- manifest path `results/.../handoffs/<stage>.tcl`

Every handoff-managed stage uses:

```tcl
set stage_paths [handoff_stage_paths ...]
handoff_bind_stage_io $stage_paths
handoff_log_paths $stage_paths
handoff_write_stage_outputs ...
```

This is the basis for restartability and stage-level debugging.

### 3.2 LEF view strategy

The flow uses LEF view switching as a first-class optimization knob. The Makefile derives the active LEF bundles:

- `LEF_FILES`
- `LEF_FILES_UPPER_COVER`
- `LEF_FILES_BOTTOM_COVER`
- `LEF_FILES_SPLIT`
- `LEF_FILES_CTS_OWNER`
- `LEF_FILES_CTS_RECEIVE`
- `LEF_FILES_CTS_FINALIZE`
- `LEF_FILES_ROUTE`
- `LEF_FILES_ROUTE_ONLY`
- `LEF_FILES_POSTROUTE_RECEIVE`
- `LEF_FILES_POSTROUTE_OWNER`

The derivation is controlled in [Makefile](Makefile):

```make
LEF_FILES_UPPER_COVER  = $(TECH_LEF) $(SC_LEF_UPPER_COVER)  $(ADDITIONAL_LEFS_UPPER_COVER)
LEF_FILES_BOTTOM_COVER = $(TECH_LEF) $(SC_LEF_BOTTOM_COVER) $(ADDITIONAL_LEFS_BOTTOM_COVER)
LEF_FILES_SPLIT        = $(TECH_LEF) $(SC_LEF) $(ADDITIONAL_LEFS_DEFAULT)
```

Interpretation:

- `LEF_FILES_UPPER_COVER` means the upper tier is represented as the COVER side, so the bottom tier is the intended active optimization side.
- `LEF_FILES_BOTTOM_COVER` means the bottom tier is represented as the COVER side, so the upper tier is the intended active optimization side.
- `LEF_FILES_SPLIT` is the full two-tier view used to classify and split mixed-tier nets.

For CTS and post-route:

- `CTS_LAYER` selects the owner tier
- `COVER_LAYER` is automatically derived as the opposite tier
- `LEF_FILES_CTS_OWNER` is the owner-active LEF view
- `LEF_FILES_CTS_RECEIVE` and `LEF_FILES_CTS_FINALIZE` use the opposite "none-CTS" view
- `LEF_FILES_POSTROUTE_RECEIVE` follows the receive-side view
- `LEF_FILES_POSTROUTE_OWNER` follows the owner-side view
- `F2F_CTS_MODE=single_trunk_handoff` is recorded as the staged CTS policy name; it does not currently select between multiple CTS algorithms
- `F2F_CTS_HANDOFFS_PER_DOMAIN` is recorded in CTS manifests, but the scripts do not currently enforce an exact handoff count per clock domain

### 3.3 Tier strategy

The tier policy is implemented in:

- [tier_cell_policy.tcl](scripts_cadence/tier_cell_policy.tcl)

The key mechanism is `apply_tier_policy <tier> ...`, which combines:

- opposite-tier library restriction through `set_dont_use`
- filler/tap/site selection for the active tier
- optional instance locking by suffix
- net-class mask through `-allow_net`
- row rebuilding through `rebuild_rows_for_site`

The important net classes are:

- `upper-only`
- `bottom-only`
- `all`

And the flow-level switches are:

- `PIN3D_ALLOW_NET_FLOW=on|off`
- `PIN3D_SPLIT_NET_FLOW=on|off`

Behavior:

- `PIN3D_ALLOW_NET_FLOW=off`
  - forces the effective allow-net class to `all`
- `PIN3D_SPLIT_NET_FLOW=off`
  - keeps the split stage in the graph, but makes it a pass-through stage

### 3.4 Placement and optimization helpers

Placement-stage optimization is implemented in:

- [place_common.tcl](scripts_cadence/place_common.tcl)

Important commands:

- `pc::setup_basic`
- `pc::run_place_step`
  - `place_opt_design`
- `pc::run_loop_opt_step`
  - `optDesign -preCTS -incr`

The flow also fixes the inactive tier explicitly with:

- `set_tier_placement_status upper fixed`
- `set_tier_placement_status bottom fixed`

This is important because LEF view selection alone does not fully prevent the inactive tier from drifting.

### 3.5 Reporting and observability

The shared metric extractor is:

- [extract_report.tcl](scripts_cadence/extract_report.tcl)

Cross-tier reports use the expanded categories:

- `Upper_Bottom`
- `Upper_IO`
- `Bottom_IO`
- `Upper_Bottom_IO`
- `Unknown_Tier`

This report model is used by:

- split-net before/after reports
- placement before/after reports
- CTS clock-only reports
- route and post-route before/after reports
- final summary generation

## 4. Make Target Map

### 4.1 Default-path public targets

| Target | Main script | Role |
|---|---|---|
| `cds-synth` | `scripts_cadence/run_genus.tcl` | Genus synthesis |
| `cds-preplace` | `scripts_cadence/innovus_preplace.tcl` | 2D floorplan and pin placement |
| `cds-tier-partition` | `scripts_cadence/tritonpart_tier_partition.tcl` | TritonPart partitioning inside Cadence flow |
| `cds-3d-flow-2dpart` | wrapper target | synth + preplace + partition |
| `cds-pre` | `scripts_cadence/generate_3d_views.py` | 2D-to-3D view generation |
| `cds-3d-floorplan` | `scripts_cadence/innovus_3d_floorplan.tcl` | 3D floorplan sizing and HBT-capacity preparation |
| `cds-3d-io` | `scripts_cadence/innovus_3d_io_place.tcl` | 3D IO placement |
| `cds-3d-split-net` | `scripts_cadence/innovus_3d_split_net.tcl` | mixed-tier net split or pass-through |
| `cds-place-macro-upper` | `scripts_cadence/innovus_placeMacro_upper.tcl` | upper macro place |
| `cds-place-macro-bottom` | `scripts_cadence/innovus_placeMacro_bottom.tcl` | bottom macro place |
| `cds-3d-pdn-only` | wrapper target | bottom PDN then upper PDN |
| `cds-place-init` | `scripts_cadence/innovus_place3D_init.tcl` | initial 3D place bootstrap |
| `cds-place-init-upper` | `scripts_cadence/innovus_place3D_init_upper.tcl` | upper incremental init |
| `cds-place-init-bottom` | `scripts_cadence/innovus_place3D_init_bottom.tcl` | bottom incremental init |
| `cds-place-upper` | `scripts_cadence/innovus_place3D_upper.tcl` | upper preCTS optimization loop |
| `cds-place-bottom` | `scripts_cadence/innovus_place3D_bottom.tcl` | bottom preCTS optimization loop |
| `cds-gp2lg` | `scripts_cadence/handoff_copy_gp2lg.tcl` | tmp-to-legalize handoff copy |
| `cds-legalize-upper` | `scripts_cadence/innovus_opt_lg_upper.tcl` | upper final legalize |
| `cds-legalize-bottom` | `scripts_cadence/innovus_opt_lg_bottom.tcl` | bottom final legalize |
| `cds-cts` | wrapper target | owner-tree + receive-opt + finalize |
| `cds-route` | `scripts_cadence/innovus_3d_route_legacy.tcl` | single-pass route (route + postRoute) |
| `cds-restore` | `scripts_cadence/innovus_3d_final-re.tcl` | final extraction with ENC restore fallback |

### 4.2 Available alternative or debug targets

| Target | Main script | Notes |
|---|---|---|
| `cds-2d_flow` | `scripts_cadence/innovus_2d_flow.tcl` | one-script 2D baseline |
| `cds-3d-pdn` | `scripts_cadence/innovus_3d_pdn.tcl` | monolithic 3D PDN handoff, not the default commercial path |
| `cds-cts-legacy` | `scripts_cadence/innovus_3d_cts_legacy.tcl` | optional CTS baseline |
| `cds-cts-owner-tree` | `scripts_cadence/innovus_3d_cts_owner_tree.tcl` | internal staged CTS target |
| `cds-cts-receive-opt` | `scripts_cadence/innovus_3d_cts_receive_opt.tcl` | internal staged CTS target |
| `cds-cts-finalize` | `scripts_cadence/innovus_3d_cts_finalize.tcl` | internal staged CTS target |
| `cds-route-new` | wrapper target | route-only + postroute-receive + postroute-owner |
| `cds-route-only` | `scripts_cadence/innovus_3d_route_only.tcl` | internal staged route target |
| `cds-postroute-receive` | `scripts_cadence/innovus_3d_postroute_receive.tcl` | internal staged post-route target |
| `cds-postroute-owner` | `scripts_cadence/innovus_3d_postroute_owner.tcl` | internal staged post-route target |
| `cds-final` | `scripts_cadence/innovus_3d_final.tcl` | final extraction directly from DEF/netlist |

## 5. Stage-by-Stage Reference

### 5.1 2D bootstrap and partition

| Target | Input | Output | LEF view | Tier strategy | Main commands | Purpose |
|---|---|---|---|---|---|---|
| `clean_all` | Existing `logs/`, `reports/`, `results/`, `objects/` | Clean workspace | N/A | N/A | shell cleanup | Reset a run directory before a fresh experiment |
| `cds-synth` | RTL + original SDC from `designs/...` | `1_synth.v`, `1_synth.sdc` | `LEF_FILES` via `lib_setup.tcl` | No tiering yet | `read_hdl`, `elaborate`, `read_sdc`, `syn_generic`, `syn_map`, `syn_opt`, `write_hdl`, `write_sdc` | Produce the netlist and SDC consumed by downstream 2D and 3D flow |
| `cds-preplace` | `1_synth.v`, `1_synth.sdc` | `2_2_floorplan_io.def`, `2_2_floorplan_io.v`, `2_2_floorplan_io.enc` | `LEF_FILES` | No tiering yet; pure 2D bootstrap | `init_design`, `floorPlan`, `generateTracks`, `place_pin.tcl`, `place_design` | Build the 2D floorplan and IO-pinned seed used by partition and later 3D conversion |
| `cds-tier-partition` | `2_2_floorplan_io.def`, `2_2_floorplan_io.v`, `1_synth.sdc` | `partition.txt`, `partition.result.tcl`, `partition.simple_plan.txt` | OpenROAD side, not Innovus LEF launch | Logical upper/bottom partitioning only; no Cadence placement yet | OpenROAD `tritonpart_tier_partition.tcl` sweep | Generate the 2-way partition used to create 3D views |
| `cds-3d-flow-2dpart` | RTL + design configs | synth + preplace + partition outputs | Wrapper | Wrapper | invokes `cds-synth`, `cds-preplace`, `cds-tier-partition` | Standard 2D bootstrap for the commercial 3D flow |
| `cds-2d_flow` | `2_2_floorplan_io.def`, `1_synth.sdc` | `5_route.def`, `5_route.v`, `${DESIGN}_postRoute.enc` | `LEF_FILES` | Single-tier 2D baseline | `place_opt_design`, `ccopt_design`, `routeDesign`, `optDesign -postRoute` | One-script 2D reference flow, mainly for baseline comparison |

### 5.2 3D view generation, floorplan, split, macro, and PDN

| Target | Input | Output | LEF view | Tier strategy | Main commands | Purpose |
|---|---|---|---|---|---|---|
| `cds-pre` | `2_2_floorplan_io.def`, `2_2_floorplan_io.v`, `partition.txt`, `map.json` | `${DESIGN}_3D.fp.def`, `${DESIGN}_3D.fp.v` | N/A, Python stage | Partition labels are mapped to upper/bottom. Heterogeneous platforms prefer area-based orientation; homogeneous platforms prefer pin-based orientation. | `generate_3d_views.py` rewrites DEF/Verilog and partition orientation | Convert the 2D preplace result into a tier-tagged 3D seed |
| `cds-3d-pdn` | `${DESIGN}_3D.fp.def`, `${DESIGN}_3D.fp.v`, `1_synth.sdc` | `2_floorplan.def`, `2_floorplan.v`, `2_floorplan.sdc` | `LEF_FILES` | Monolithic 3D floorplan path; not the default launcher path | `init_design`, `defIn`, tier-aware `floorPlan`, `place_pin.tcl`, platform `pdn_config.tcl` | Build a single combined 3D floorplan+PDN handoff |
| `cds-3d-floorplan` | `${DESIGN}_3D.fp.v`, `1_synth.sdc` | `2_3_floorplan_3d.def`, `2_3_floorplan_3d.v` | `LEF_FILES` | No movement restriction yet; estimates cross-tier pressure before detailed optimization | `extract_cross_tier_nets`, `tier::core_wh_for_max_tier_util`, optional `create_hb_layer_obs`, `floorPlan`, `generateTracks` | Size the 3D core and optionally reserve HBT capacity before later stages |
| `cds-3d-io` | `2_3_floorplan_3d.def`, `2_3_floorplan_3d.v`, `1_synth.sdc` | `2_4_floorplan_io.def`, `2_4_floorplan_io.v` | `LEF_FILES` | IO-only update on top of the 3D floorplan | `handoff_init_design_from_paths`, `place_pin.tcl` | Rebuild final 3D IO placement after floorplan sizing |
| `cds-3d-split-net` | `2_4_floorplan_io.def`, `2_4_floorplan_io.v`, `1_synth.sdc` | updated `2_4_floorplan_io.def`, `2_4_floorplan_io.v`, split reports | `LEF_FILES_SPLIT` | Full two-tier visibility. `PIN3D_SPLIT_NET_FLOW=off` keeps the stage but turns it into pass-through. | `extract_cross_tier_nets`, `split_net.tcl`, in-place handoff overwrite | Reduce mixed-fanout nets before macro placement and detailed optimization |
| `cds-place-macro-upper` | `2_4_floorplan_io.def`, `2_4_floorplan_io.v`, `1_synth.sdc` | `2_5_place_macro_upper.def`, `2_5_place_macro_upper.v` | `LEF_FILES_BOTTOM_COVER` | Upper tier active, bottom tier treated as cover | `apply_tier_policy upper -fixlib 1`, `pmu::run_tier_macro_place upper` | Place upper macros while protecting bottom-tier visibility |
| `cds-place-macro-bottom` | `2_5_place_macro_upper.def`, `2_5_place_macro_upper.v`, `1_synth.sdc` | `2_5_place_macro_bottom.def`, `2_5_place_macro_bottom.v` | `LEF_FILES_UPPER_COVER` | Bottom tier active, upper tier treated as cover | `apply_tier_policy bottom -fixlib 1`, `pmu::run_tier_macro_place bottom` | Place bottom macros after upper macros are fixed |
| `cds-3d-pdn-only-bottom` | `2_5_place_macro_bottom.def`, `2_5_place_macro_bottom.v`, `1_synth.sdc` | `2_6_floorplan_pdn_bottom.def`, `2_6_floorplan_pdn_bottom.v` | `LEF_FILES_UPPER_COVER` | Bottom tier active, upper tier covered; rows rebuilt using `BOTTOM_SITE` or `PLACE_SITE` | `rebuild_rows_for_site`, platform `pdn_config_bottom.tcl` | Build bottom-tier PDN only |
| `cds-3d-pdn-only-upper` | `2_6_floorplan_pdn_bottom.def`, `2_6_floorplan_pdn_bottom.v`, `1_synth.sdc` | `2_6_floorplan_pdn.def`, `2_6_floorplan_pdn.v`, aliases `2_floorplan.def`, `2_floorplan.v`, `2_floorplan.sdc` | `LEF_FILES_BOTTOM_COVER` | Upper tier active, bottom tier covered; rows rebuilt using `UPPER_SITE` or `PLACE_SITE` | `rebuild_rows_for_site`, platform `pdn_config_upper.tcl` | Build upper-tier PDN and publish the canonical `2_floorplan.*` handoff |
| `cds-3d-pdn-only` | wrapper | wrapper | wrapper | wrapper | calls bottom then upper PDN-only targets | The default commercial path for 3D PDN handoff construction |

### 5.3 Placement, outer-loop optimization, and legalization

| Target | Input | Output | LEF view | Tier strategy | Main commands | Purpose |
|---|---|---|---|---|---|---|
| `cds-place-init` | `2_floorplan.def`, `2_floorplan.v`, `2_floorplan.sdc` | `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v` | `LEF_FILES_UPPER_COVER` | Upper tier fixed. Bottom tier bootstrapped with requested default allow-net `bottom-only`. | `set_tier_placement_status upper fixed`, `apply_tier_policy bottom -fixlib 1 -allow_net ...`, `place_design` | Produce the initial temp placement handoff |
| `cds-place-init-upper` | `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v`, `2_floorplan.sdc` | updated `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v` | `LEF_FILES_BOTTOM_COVER` | Bottom tier fixed. Upper tier incremental init with default `upper-only`. | `set_tier_placement_status bottom fixed`, `apply_tier_policy upper -fixlib 1 -allow_net ...`, `pc::run_loop_opt_step init_upper` | Give the upper tier one incremental initialization pass |
| `cds-place-init-bottom` | `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v`, `2_floorplan.sdc` | updated `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v` | `LEF_FILES_UPPER_COVER` | Upper tier fixed. Bottom tier incremental init with default `bottom-only`. | `set_tier_placement_status upper fixed`, `apply_tier_policy bottom -fixlib 1 -allow_net ...`, `pc::run_loop_opt_step init_bottom` | Give the bottom tier one incremental initialization pass |
| `cds-place-upper` | `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v`, `2_floorplan.sdc` | updated `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v`, `${DESIGN}_3d_after_upper.enc` | `LEF_FILES_BOTTOM_COVER` | Bottom tier fixed. Requested allow-net comes from `TIER_ALLOW_NET`; current launcher sets `upper-only`. | `apply_tier_policy upper -fixlib 1 -allow_net ...`, `pc::run_place_step` | Upper-tier outer-loop preCTS optimization |
| `cds-place-bottom` | `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v`, `2_floorplan.sdc` | updated `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v`, `${DESIGN}_3d_after_bottom.enc` | `LEF_FILES_UPPER_COVER` | Upper tier fixed. Requested allow-net comes from `TIER_ALLOW_NET`; current launcher sets `bottom-only`. | `apply_tier_policy bottom -fixlib 1 -allow_net ...`, `pc::run_place_step` | Bottom-tier outer-loop preCTS optimization |
| `cds-gp2lg` | `${DESIGN}_3D.tmp.def`, `${DESIGN}_3D.tmp.v`, `2_floorplan.sdc` | `${DESIGN}_3D.lg.def`, `${DESIGN}_3D.lg.v` | N/A, Tcl copy stage | No optimization; handoff normalization only | `handoff_copy_gp2lg.tcl` | Publish the legalize-stage input names cleanly |
| `cds-legalize-upper` | `${DESIGN}_3D.lg.def`, `${DESIGN}_3D.lg.v`, `2_floorplan.sdc` | updated `${DESIGN}_3D.lg.def`, `${DESIGN}_3D.lg.v`, aliases `3_place.def`, `3_place.v`, `3_place.sdc` | `LEF_FILES_BOTTOM_COVER` | Bottom tier fixed. Default requested allow-net is forced to `upper-only`. | `apply_tier_policy upper -fixlib 1 -allow_net ...`, `pc::run_loop_opt_step legalize_upper`, `checkPlace` | Final upper-tier incremental legalization and polish |
| `cds-legalize-bottom` | `${DESIGN}_3D.lg.def`, `${DESIGN}_3D.lg.v`, `2_floorplan.sdc` | updated `${DESIGN}_3D.lg.def`, `${DESIGN}_3D.lg.v`, aliases `3_place.def`, `3_place.v`, `3_place.sdc` | `LEF_FILES_UPPER_COVER` | Upper tier fixed. Default requested allow-net is forced to `bottom-only`. | `apply_tier_policy bottom -fixlib 1 -allow_net ...`, `pc::run_loop_opt_step legalize_bottom`, `checkPlace` | Final bottom-tier incremental legalization and polish |

### 5.4 Clock tree synthesis

| Target | Input | Output | LEF view | Tier strategy | Main commands | Purpose |
|---|---|---|---|---|---|---|
| `cds-cts` | `3_place.def`, `3_place.v`, `3_place.sdc` | `4_cts.def`, `4_cts.v`, `4_cts.sdc` | Wrapper over staged subtargets | `CTS_LAYER` chooses owner tier; receive tier is the opposite | invokes owner-tree, receive-opt, finalize | Public staged CTS flow |
| `cds-cts-owner-tree` | `3_place.def`, `3_place.v`, `3_place.sdc` | `4_0_cts_owner_tree.def`, `4_0_cts_owner_tree.v`, `4_0_cts_owner_tree.sdc` | `LEF_FILES_CTS_OWNER` | Active tier = `CTS_LAYER`, fixed tier = opposite, allow-net = owner-only | `cts_init_design_from_paths`, `apply_tier_policy ...`, `create_ccopt_clock_tree_spec`, `ccopt_design` | Build the owner-tier clock tree |
| `cds-cts-receive-opt` | `4_0_cts_owner_tree.def`, `4_0_cts_owner_tree.v`, `4_0_cts_owner_tree.sdc` | `4_1_cts_receive_opt.def`, `4_1_cts_receive_opt.v`, `4_1_cts_receive_opt.sdc` | `LEF_FILES_CTS_RECEIVE` | Active tier = receive tier, fixed tier = owner tier, allow-net = receive-only | `apply_tier_policy ...`, `optDesign -postCTS` | Repair receive-side clock-related logic without rebuilding the owner tree |
| `cds-cts-finalize` | `4_1_cts_receive_opt.def`, `4_1_cts_receive_opt.v`, `4_1_cts_receive_opt.sdc` | `4_3_cts_finalize.def`, `4_3_cts_finalize.v`, `4_3_cts_finalize.sdc`, aliases `4_cts.def`, `4_cts.v`, `4_cts.sdc` | `LEF_FILES_CTS_FINALIZE` | No new active tier optimization; reporting and handoff finalization only | `cts_init_design_from_paths`, `extract_cross_tier_nets`, `cts_write_stage_outputs` | Freeze and publish the final CTS handoff |
| `cds-cts-legacy` | `3_place.def`, `3_place.v`, `3_place.sdc` | `4_1_cts.def`, `4_1_cts.v`, `4_1_cts.sdc`, aliases `4_cts.def`, `4_cts.v`, `4_cts.sdc` | `LEF_FILES_CTS` | Single-pass owner-side CTS baseline | `apply_tier_policy`, `create_ccopt_clock_tree_spec`, `ccopt_design` | Optional CTS baseline |

### 5.5 Route and final reporting

| Target | Input | Output | LEF view | Tier strategy | Main commands | Purpose |
|---|---|---|---|---|---|---|
| `cds-route` | `4_cts.def`, `4_cts.v`, `4_cts.sdc` | `5_route.def`, `5_route.v`, `5_route.sdc`, `${DESIGN}_postRoute.enc.dat` | `LEF_FILES_ROUTE` | Single-pass route plus owner-tier postRoute repair | `routeDesign`, `apply_tier_policy [cts_owner_tier]`, `optDesign -postRoute` | Default route target in the commercial launcher |
| `cds-route-new` | `4_cts.def`, `4_cts.v`, `4_cts.sdc` | `5_route.def`, `5_route.v`, `5_route.sdc` | Wrapper over staged route subtargets | Receive-side then owner-side postRoute | invokes route-only, postroute-receive, postroute-owner | Alternative staged route flow |
| `cds-route-only` | `4_cts.def`, `4_cts.v`, `4_cts.sdc` | `5_0_route.def`, `5_0_route.v`, `5_0_route.sdc`, `${DESIGN}_route_only.enc.dat` | `LEF_FILES_ROUTE_ONLY` | No tier-specific repair yet; pure wiring realization | `route_init_design_from_paths`, `route_apply_router_setup`, `routeDesign` | Separate wire realization from post-route ECO |
| `cds-postroute-receive` | `5_0_route.def`, `5_0_route.v`, `5_0_route.sdc`, `${DESIGN}_route_only.enc.dat` | `5_1_postroute_receive.def`, `5_1_postroute_receive.v`, `5_1_postroute_receive.sdc` | `LEF_FILES_POSTROUTE_RECEIVE` | Active tier = receive tier, fixed tier = owner tier, allow-net = receive-only | `restoreDesign` if ENC exists, `apply_tier_policy`, `optDesign -postRoute -incr` | Receive-side post-route ECO |
| `cds-postroute-owner` | `5_1_postroute_receive.def`, `5_1_postroute_receive.v`, `5_1_postroute_receive.sdc` | `5_2_postroute_owner.def`, `5_2_postroute_owner.v`, `5_2_postroute_owner.sdc`, aliases `5_route.def`, `5_route.v`, `5_route.sdc` | `LEF_FILES_POSTROUTE_OWNER` | Active tier = owner tier, fixed tier = receive tier, allow-net = owner-only | `apply_tier_policy`, `optDesign -postRoute -incr` | Owner-side post-route ECO and final route handoff publication |
| `cds-final` | `5_route.def`, `5_route.v`, `5_route.sdc` | `6_final.png`, `final_metrics.csv`, `final_summary.txt` | Reopens routed handoff using `LEF_FILES` | No optimization; report-only | `init_design`, `defIn`, `extract_report -postRoute`, `dumpPictures` | Extract final metrics directly from DEF/netlist |
| `cds-restore` | `5_route.def`, `5_route.v`, `5_route.sdc`, `${DESIGN}_postRoute.enc.dat` | `6_final.png`, `final_metrics.csv`, `final_summary.txt` | Reopens routed handoff using `LEF_FILES` | No optimization; report-only with ENC restore preference | `restoreDesign` if ENC exists else `init_design` + `defIn`, then `extract_report -postRoute` | Preferred final reporting target in the commercial launcher |

## 6. How Optimization Is Implemented

The current flow does not rely on one single optimizer call. It implements optimization as a coordinated strategy across partitioning, view selection, tier constraints, stage sequencing, and metric feedback.

### 6.1 Optimization starts before Innovus

The optimization pipeline begins with:

- `cds-synth`
- `cds-preplace`
- `cds-tier-partition`
- `cds-pre`

This is important because the later 3D physical stages do not start from an unstructured dual-tier design. They start from:

- a synthesized netlist
- a preplaced 2D DEF
- a TritonPart partition result
- a rewritten 3D DEF/Verilog with tier-tagged views

So the first optimization layer is the logical partition itself.

### 6.2 LEF view selection is an optimization knob

The Makefile deliberately swaps LEF bundles between stages. This is not file plumbing. It is how the flow controls what Innovus can physically optimize.

Examples:

- `cds-place-upper` uses `LEF_FILES_BOTTOM_COVER`
  - upper tier active
  - bottom tier treated as cover/fixed
- `cds-place-bottom` uses `LEF_FILES_UPPER_COVER`
  - bottom tier active
  - upper tier treated as cover/fixed
- `cds-cts-owner-tree` uses `LEF_FILES_CTS_OWNER`
  - owner tier active according to `CTS_LAYER`
- `cds-postroute-receive` uses `LEF_FILES_POSTROUTE_RECEIVE`
  - receive tier active after routing

This means the optimizer sees a deliberately restricted physical world in each stage.

### 6.3 Tier constraints are applied explicitly

The flow never assumes the inactive tier will stay still by itself. It combines:

- `apply_tier_policy <active_tier> -fixlib 1 -allow_net ...`
- `set_tier_placement_status <inactive_tier> fixed`

This creates the optimization window for the current pass:

- library availability is biased toward the active tier
- inactive COVER cells are fixed
- fillers and sites are switched for the active tier
- only selected net classes are movable when allow-net is enabled

### 6.4 Allow-net and split-net implement the co-optimization policy

There are two independent high-level switches:

- `PIN3D_ALLOW_NET_FLOW`
- `PIN3D_SPLIT_NET_FLOW`

`PIN3D_ALLOW_NET_FLOW` changes whether stage-local `allow_net` intent is honored or collapsed to `all`.

`PIN3D_SPLIT_NET_FLOW` changes whether the split stage actually inserts split buffers and rewrites the post-IO handoff, or stays as a pass-through report-only stage.

The Cadence split-net stage uses the same cost-based tier selection policy as the OpenROAD split stage.

For each legal mixed-fanout signal net, the stage evaluates placing a regular tier-local `BUF*` on `upper` and on `bottom`. The selected tier moves that tier's sinks behind the branch net, while the opposite tier's sinks remain on the original net. Existing clock, PG, special-net, unsupported driver and unsupported top-level sink rewiring skips remain in place, and successful splits must leave both the original net and branch net `mixed_fanout`-pure.

The decision score is:

```text
score(t) = w_util * util_penalty(t) + w_hbt * hbt_penalty(t) + w_area * buffer_area_penalty(t)
```

Default parameters are `u_safe=0.60`, `alpha=12.0`, `w_util=1.0`, `w_hbt=2.5`, `w_area=400.0`, high-util forbid threshold `0.80`, and near-tie threshold `5%`. The utilization term is exponential above `u_safe`, so high-util tiers are penalized sharply. The HBT term uses `estimated_extra_hbt`, not actual routed HBT count:

- if `buffer_tier != driver_tier`, `estimated_extra_hbt = 1`
- if `buffer_tier == driver_tier`, `estimated_extra_hbt = retained_opposite_tier_sink_count`
- `hbt_penalty = log2(1 + estimated_extra_hbt)`

The area term uses the chosen split buffer master area normalized by the current
core area:

- `buffer_area_penalty = chosen_buffer_area / core_area`

This intentionally makes the area term more visible on very small designs,
where a few added buffers can perturb density much more than on large designs.

This HBT value is only a split-decision cost proxy. It should not be interpreted as final physical HBT usage after route. Cadence estimates tier utilization once per split run from tier-classified instance area divided by the current core area, then reuses that global value for all candidate nets. The area term reuses the same core area and the chosen candidate buffer master area.

This is the main mechanism used in the current commercial comparison experiments.

### 6.5 PreCTS optimization is intentionally staged and iterative

The current launcher runs:

1. `cds-place-init`
2. `cds-place-init-upper`
3. `cds-place-init-bottom`
4. outer loop of:
   - `cds-place-upper`
   - `cds-place-bottom`
5. `cds-gp2lg`
6. `cds-legalize-upper`
7. `cds-legalize-bottom`

This means preCTS optimization is not one placement call. It is an alternating upper/bottom sequence with repeated handoffs and measurement points.

### 6.6 CTS is split by semantic ownership

The staged CTS flow is:

1. `cds-cts-owner-tree`
2. `cds-cts-receive-opt`
3. `cds-cts-finalize`

This separates:

- owner-tier tree construction
- receive-tier clock repair/optimization
- final publication

Instead of letting one opaque CTS pass introduce and repair everything at once. The `single_trunk_handoff` name describes this staged owner/receive policy and should not be read as a hard guarantee that the current scripts enforce exactly one physical handoff point per clock domain.

### 6.7 Staged route option

The repository contains:

- `cds-route-only`
- `cds-postroute-receive`
- `cds-postroute-owner`

This staged route path exists so wire realization and post-route tier-specific ECO can be separated when needed.

The current commercial launcher still uses `cds-route` for robustness, but the staged route path is already implemented and documented.

### 6.8 Optimization is feedback-driven by reports

The flow continuously measures:

- split-net before/after cross-tier reports
- placement before/after cross-tier reports
- CTS clock-only cross-tier reports
- route before/after cross-tier reports
- final summary metrics

The report model distinguishes:

- `Upper_Bottom`
- `Upper_IO`
- `Bottom_IO`
- `Upper_Bottom_IO`
- `Unknown_Tier`

This is how the flow turns each stage into an observable optimization step instead of a black box.

## 7. Practical Reading Order

If you need to debug or extend the commercial flow, the most useful reading order is:

1. [test/commercial/CDS_3D_NEW_FLOW.sh](test/commercial/CDS_3D_NEW_FLOW.sh)
2. [Makefile](Makefile)
3. [handoff_manager.tcl](scripts_cadence/handoff_manager.tcl)
4. [tier_cell_policy.tcl](scripts_cadence/tier_cell_policy.tcl)
5. [place_common.tcl](scripts_cadence/place_common.tcl)
6. [cts_stage_common.tcl](scripts_cadence/cts_stage_common.tcl)
7. [route_stage_common.tcl](scripts_cadence/route_stage_common.tcl)
8. The stage entry scripts for the stage you want to change

This order matches the real control flow:

- shell launcher
- `make` orchestration
- handoff contract
- tier and LEF policy
- stage-specific tool commands
