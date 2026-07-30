# Copyright 2021 Max Planck Institute for Software Systems, and
# National University of Singapore
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# Compilers and python interpreter (overridable by conda / the environment).
CXX               ?= c++
PYTHON            ?= python

# Where "make corundum-install" places the binary. Inside a conda build this is
# the host/build prefix; for a local dev build override it, e.g. PREFIX=$(pwd)/out.
PREFIX            ?= $(CURDIR)/out

# simbricks-lib layout: headers under $(SIMBRICKS_INC_DIR) and the static libs
# the adapter links against under $(SIMBRICKS_LIB_DIR). simbricks-lib is itself a
# conda package, so both default off $(PREFIX) — exactly where it installs its
# headers ($(PREFIX)/include) and its flat lib*.a archives ($(PREFIX)/lib/simbricks).
# Override for a local dev build against a simbricks tree installed elsewhere.
SIMBRICKS_INC_DIR ?= $(PREFIX)/include
SIMBRICKS_LIB_DIR ?= $(PREFIX)/lib

# Python packages (each has its own pyproject.toml).
CORUNDUM_PY_SIM   := corundum_sim_rtl_py
CORUNDUM_PY_SYS   := corundum_sys_py

# Optional: redirect conda-build output, e.g. OUTPUT_FOLDER=./conda-out.
OUTPUT_FOLDER     ?=
OUTPUT_FLAG       := $(if $(OUTPUT_FOLDER),--output-folder $(OUTPUT_FOLDER))
# Conda channels searched by `conda build`. The SimBricks channel hosts external
# deps not built here (e.g. simbricks-lib, simbricks-orchestration); conda-forge
# provides the rest. Override to point at a different channel if needed.
SIMB_CONDA_CHANNEL:= -c https://conda.simbricks.io/latest
BASE_BUILD_CMD    := conda build $(SIMB_CONDA_CHANNEL) -m conda-recipes/conda_build_config.yaml $(OUTPUT_FLAG)

## --- corundum verilated adapter (C++ in adapter/, RTL in the corundum submodule) ---

dir_corundum := ./corundum
verilator_dir_corundum := $(dir_corundum)/obj_dir
verilog_interface_name := mqnic_core_axi
verilator_interface_name := V$(verilog_interface_name)
verilator_src_corundum := $(verilator_dir_corundum)/$(verilator_interface_name).cpp
verilator_bin_corundum := $(verilator_dir_corundum)/$(verilator_interface_name)
adapter_main := adapter/corundum_simbricks_adapter
corundum_simbricks_adapter_src := $(adapter_main).cpp
corundum_simbricks_adapter_bin := $(adapter_main)

mqnic_dir := $(dir_corundum)/modules/mqnic

# Kernel build tree the out-of-tree mqnic module compiles against. Defaults to
# the running kernel's headers, for use when `make driver` runs INSIDE the target
# image.
KDIR ?= /lib/modules/$(shell uname -r)/build
KVER ?= $(shell uname -r)

# simbricks static libs the adapter links against, resolved the standard way
# with -L/-l from $(SIMBRICKS_LIB_DIR) (matches the flat lib*.a layout the
# simbricks-lib conda package installs). Passed via Verilator's USER_LDLIBS hook
# so they land in LDLIBS, i.e. AFTER the objects on the link line (required for
# static archives), and grouped so any inter-lib references resolve.
SIMBRICKS_LDLIBS := -L$(SIMBRICKS_LIB_DIR) \
    -Wl,--start-group -lnicif -lnetwork -lpcie -lbase -lparser -Wl,--end-group

VERILATOR = verilator
VFLAGS = -Wno-WIDTH -Wno-PINMISSING -Wno-LITENDIAN -Wno-IMPLICIT -Wno-SELRANGE \
    -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-UNOPTFLAT --timescale 1ns/1ps

TOPLEVEL = mqnic_core_axi


$(verilator_src_corundum):
	$(VERILATOR) $(VFLAGS) --cc -O3 \
	    -CFLAGS "-I$(SIMBRICKS_INC_DIR) -I$(abspath $(verilator_dir_corundum)) -iquote $(SIMBRICKS_INC_DIR) -O3 -g -Wall -Wno-maybe-uninitialized" \
	    --Mdir $(verilator_dir_corundum) \
		--top-module $(verilog_interface_name) \
		--trace \
	    -y $(dir_corundum)/fpga/common/rtl \
		-y $(dir_corundum)/fpga/common/lib/axis/rtl \
		-y $(dir_corundum)/fpga/common/lib/eth/rtl \
		-y $(dir_corundum)/fpga/common/lib/pcie/rtl \
	    -y $(dir_corundum)/fpga/lib/axi/rtl \
	    -y $(dir_corundum)/fpga/lib/eth/lib/axis/rtl/ \
	    -y $(dir_corundum)/fpga/lib/pcie/rtl \
	    $(dir_corundum)/fpga/common/rtl/$(verilog_interface_name).v \
	    $(dir_corundum)/fpga/common/rtl/mqnic_tx_scheduler_block_rr.v \
		--exe $(abspath $(corundum_simbricks_adapter_src))

$(verilator_bin_corundum): $(verilator_src_corundum) $(corundum_simbricks_adapter_src)
	$(MAKE) -C $(verilator_dir_corundum) -f $(verilator_interface_name).mk \
	    USER_LDLIBS="$(SIMBRICKS_LDLIBS)"

$(corundum_simbricks_adapter_bin): $(verilator_bin_corundum)
	cp $< $@

# Build the adapter binary (adapter/corundum_simbricks_adapter).
corundum-build: $(corundum_simbricks_adapter_bin)

# Backward-compatible alias for the old target name.
adapter: corundum-build

# Install the adapter into $(PREFIX)/bin as simb_corundum (the name the python
# orchestration invokes via PATH). Builds first via the dependency.
corundum-install: corundum-build
	install -Dm755 $(corundum_simbricks_adapter_bin) $(PREFIX)/bin/simb_corundum

# Build the out-of-tree mqnic kernel module (+ userspace utils) against $(KDIR).
# Meant to run inside the target image during image build.
driver:
	$(MAKE) -C $(KDIR) M=$(abspath $(mqnic_dir)) modules
	$(MAKE) -C $(dir_corundum)/utils

# Install the built module into the kernel's module tree and refresh depmod.
driver-install: driver
	install -Dm644 $(mqnic_dir)/mqnic.ko /lib/modules/$(KVER)/extra/mqnic.ko
	depmod -a $(KVER)

## --- Python packages (corundum_sim_rtl_py/, corundum_sys_py/) ---------------

# Editable installs for local development (sys first so sim's imports resolve).
corundum-python-develop:
	$(PYTHON) -m pip install -e ./$(CORUNDUM_PY_SYS)
	$(PYTHON) -m pip install -e ./$(CORUNDUM_PY_SIM)

## --- Conda packages --------------------------------------------------------

corundum-sys-py-conda:
	$(BASE_BUILD_CMD) conda-recipes/simbricks-corundum-sys-py

corundum-sim-rtl-py-conda: corundum-sys-py-conda
	$(BASE_BUILD_CMD) conda-recipes/simbricks-corundum-sim-rtl-py

corundum-sim-rtl-bin-conda:
	$(BASE_BUILD_CMD) conda-recipes/simbricks-corundum-sim-rtl-bin

# Build all conda packages (python hulls first, then the compiled binary). Run
# sequentially (no -j) so each build finds the previously-built local packages.
conda-packages: corundum-sim-rtl-py-conda corundum-sys-py-conda corundum-sim-rtl-bin-conda


## --- PyPI packages ---------------------------------------------------------

pypi-build:
	poetry build -C $(CORUNDUM_PY_SYS)
    poetry build -C $(CORUNDUM_PY_SIM)

pypi-publish: pypi-build
	poetry publish -C $(CORUNDUM_PY_SYS)
    poetry publish -C $(CORUNDUM_PY_SIM)

## --- Default target ----------------------------------------------------------

# Default: build all conda packages.
all: conda-packages
.DEFAULT_GOAL := all

## --- Housekeeping ----------------------------------------------------------

clean:
	rm -rf $(corundum_simbricks_adapter_bin) $(verilator_dir_corundum) ready out
	rm -rf $(CORUNDUM_PY_SIM)/dist $(CORUNDUM_PY_SYS)/dist

.PHONY: all corundum-build adapter corundum-install driver driver-install \
		corundum-python-develop corundum-sys-py-conda corundum-sim-rtl-py-conda \
		corundum-sim-rtl-bin-conda conda-packages clean
