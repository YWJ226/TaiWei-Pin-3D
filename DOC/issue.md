# Known Issues

## Cadence Macro Cases Can Crash With OpenROAD-Style Additional Layers

### Summary

In Cadence 3D flow, macro-containing designs can crash during `cds-place-upper`
when the technology/view stack includes the OpenROAD-style additional routing
layers such as `M2_add` / `M3_add`.

The current evidence points to an Innovus internal optimizer failure triggered
by the combination of:

- macro-containing designs
- `place_opt_design`-based upper placement
- OpenROAD-style additional-layer setup in the Cadence flow

This is currently treated as a flow compatibility issue, not a normal design
violation.

### Affected Scope

- Cadence flow
- macro-containing cases such as `swerv_wrapper`
- especially `nangate45_3D` mixed-view runs like `cds_ordtech`
- stage:
  - `cds-place-upper`

### Typical Symptoms

- repeated internal asserts in Innovus:
  - `coeTransform.hpp:2625:getTopoLaCount`
- final internal crash:
  - `Innovus terminated by internal (SEGV) error/signal`
- trailing worker-thread stacks stuck in `pthread_cond_wait`
  - this is a post-crash symptom, not the root cause

### Evidence

Relevant logs:

- [3_place_upper.upper-only.log](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/logs/nangate45_3D/swerv_wrapper/cds_ordtech/3_place_upper.upper-only.log)
- [3_place_upper.upper-only.log](/export/home/zhiyuzheng/Projects/TaiWei_Platform/TaiWei_DEV/TaiWei/TaiWei-Pin-3D/logs/nangate45_3D/swerv_wrapper/cds_ordtech_nosplit/3_place_upper.upper-only.log)

Common indicators seen in both split and no-split runs:

- additional-layer routing setup is active:
  - `setDesignMode -topRoutingLayer M3_add`
- additional-layer pitch warnings appear:
  - generated pitch mismatch on `M2_add`
- extra tech inconsistency warning appears:
  - `IMPRM-132 Missing VIARULE GENERATE definition between M19/M20`
- later, the optimizer crashes in the same internal topo path:
  - `getTopoLaCount`
  - `coeSetupOptimizer`
  - `rdaOptDesignCL::run`

The same signature appears in both:

- `cds_ordtech`
- `cds_ordtech_nosplit`

So this issue is not currently attributed only to split-buffer insertion.

### Current Interpretation

The current working interpretation is:

- pure `split_net` is not the primary root cause
- the main trigger is the Cadence upper placement optimization flow running on
  a macro-containing design under the OpenROAD-style additional-layer setup
- this likely exposes an Innovus internal bug or unsupported flow combination

### Current Workaround

Until this is fully fixed, avoid using the OpenROAD-style additional-layer
setup for Cadence macro cases in `place-upper`, or reduce the stage to a safer
placement mode.

Practical mitigations:

- avoid the additional-layer tech/view mix for macro cases
- avoid `place_opt_design` on the affected macro cases when possible
- prefer a simpler `place_design`-style upper placement for debug

### Notes

- This issue has only been clearly reproduced on macro-containing Cadence
  cases so far.
- Non-macro cases may still run with the same additional-layer setup.
- If this issue is revisited later, compare against:
  - macro-free Cadence cases
  - the same macro case without additional layers
  - the same macro case with reduced placement optimization effort
