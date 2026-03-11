#!/bin/bash
source "env.sh"

export DESIGN_DIMENSION="3D"
export USE_FLOW="openroad"
export FLOW_VARIANT="base"
# export OPEN_GUI=0
export VISUALIZE_FINAL=1
export LOG_DIR=./logs/asap7_nangate45_3D/gcd/base
export OBJECTS_DIR=./objects/asap7_nangate45_3D/gcd/base
export REPORTS_DIR=./reports/asap7_nangate45_3D/gcd/base
export RESULTS_DIR=./results/asap7_nangate45_3D/gcd/base
make DESIGN_CONFIG=designs/asap7_nangate45_3D/gcd/config.mk clean_all
make DESIGN_CONFIG=designs/asap7_nangate45_3D/gcd/config2d.mk ord-3d-flow-2dpart
make DESIGN_CONFIG=designs/asap7_nangate45_3D/gcd/config.mk ord-3d-flow
# make DESIGN_CONFIG=designs/asap7_nangate45_3D/gcd/config.mk ord-final
