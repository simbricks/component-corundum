#!/bin/bash
set -eux

# Build and install the corundum adapter binary as $PREFIX/bin/simb_corundum.
# The Makefile defaults SIMBRICKS_INC_DIR/SIMBRICKS_LIB_DIR off PREFIX, which is
# where simbricks-lib (a host dep) installs its headers and static libs.
make corundum-install PREFIX="${PREFIX}"
