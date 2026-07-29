<!-- NOTE: This file is written for the https://github.com/simbricks/component-corundum
     repository. Move it there as README.md; its relative links refer to that repo's tree. -->

# component-corundum

SimBricks component repo wrapping the [Corundum](https://github.com/corundum/corundum) open-source,
high-performance FPGA-based NIC. It bundles the Corundum RTL (as a submodule), the SimBricks adapter
that drives the Verilated design, and the Python packages that integrate the NIC into the SimBricks
orchestration framework, and ships all of it as conda packages so users can install just the
simulator they need.

Corundum comes with a Linux driver (`mqnic`), so unlike a pure CPU or network simulator this
component also has a **guest-side** piece: the driver has to be built into the disk image the
simulated hosts boot. See [The guest driver and disk images](#the-guest-driver-and-disk-images).

## Layout

| Path | Description |
|---|---|
| `corundum/` | Git submodule with the SimBricks fork of the Corundum sources (RTL, the `mqnic` driver and its userspace utils). |
| `corundum-verilog.patch` | The Verilog and driver fixes needed to verilate Corundum and run it under SimBricks. Kept for reference — the build does **not** apply it, since the forked submodule already carries these changes. |
| `adapter/corundum_simbricks_adapter.cpp` | The SimBricks adapter. It is also the driver of the Verilated design: it instantiates the top-level module and bridges it to the SimBricks PCIe and Ethernet protocols. |
| `corundum_sys_py/` | Python *system* package (`simbricks-corundum-sys-py`), exposing `simbricks.components.corundum.system`. |
| `corundum_sim_rtl_py/` | Python *simulation* package (`simbricks-corundum-sim-rtl-py`), exposing `simbricks.components.corundum.simulation`. |
| `conda-recipes/simbricks-corundum-sys-py/` | Conda recipe for the noarch system python package. |
| `conda-recipes/simbricks-corundum-sim-rtl-py/` | Conda recipe for the noarch simulation python package. |
| `conda-recipes/simbricks-corundum-sim-rtl-bin/` | Conda recipe for the compiled adapter (`simbricks-corundum-sim-rtl-bin`). |
| `conda-recipes/conda_build_config.yaml` | Shared version / URL variables used by all recipes. |
| `Makefile` | Top-level driver for the builds below. |
| `.devcontainer/conda-build/` | VS Code dev container providing a ready-to-use conda build environment. |

## Conda packages

This repo produces three packages:

- **`simbricks-corundum-sys-py`** — noarch Python package with the *system* components,
  `CorundumNIC` and `CorundumLinuxHost`. These describe *what* is being built and carry no
  simulator dependency, so a system description can be written (and shared) without installing the
  RTL simulation.
- **`simbricks-corundum-sim-rtl-py`** — noarch Python package with `CorundumVerilatorNICSim`, the
  simulator choice for a `CorundumNIC`. It builds on the system package (both live in the shared
  `simbricks.components.corundum` namespace) and pins it with `==` to the co-built version.
- **`simbricks-corundum-sim-rtl-bin`** — the compiled adapter, installed as **`simb_corundum` in
  `$PREFIX/bin`**. That name is not incidental: `CorundumVerilatorNICSim` passes
  `executable="simb_corundum"` and the binary is resolved through `PATH`. The package depends on `simbricks-corundum-sim-rtl-py` at the same version, so installing the simulator
  also pulls in its orchestration glue (and transitively the system package).

External dependencies that are *not* built here — `simbricks-lib` (needed to build the adapter) and
`simbricks-orchestration` / `simbricks-utils` (runtime deps of the python packages) — are resolved
automatically from the public SimBricks conda channel (`https://conda.simbricks.io/latest`, wired
into the build via the Makefile's `SIMB_CONDA_CHANNEL`). You do **not** need to install them by hand.

## Prerequisites

- Initialize the Corundum submodule: `git submodule update --init`.
- A conda installation with `conda build` available. The easiest path is the bundled dev container
  (`.devcontainer/conda-build/`), based on the SimBricks `conda-build-env` image — "Reopen in
  Container" in VS Code and everything (conda-build, toolchain, channels) is ready.
- If not using the dev container: a C/C++ toolchain, `make`, and
  [Verilator](https://www.veripool.org/verilator/) to compile the Corundum RTL.

## Building the conda packages

```sh
# Build all three packages in dependency order: the python packages first, then
# the binary package (which depends on them and resolves them from the local
# channel). External deps are pulled from the SimBricks channel automatically.
make conda-packages          # this is also the default `make` target

# Or build them individually.
make corundum-sys-py-conda
make corundum-sim-rtl-py-conda    # builds corundum-sys-py-conda first
make corundum-sim-rtl-bin-conda

# Redirect conda-build output if desired.
make conda-packages OUTPUT_FOLDER=./conda-out
```

Build these sequentially (do not pass `-j`), so each build finds the packages produced by the
previous one in the local channel.

## The guest driver and disk images

Corundum's NIC is driven by the out-of-tree `mqnic` Linux kernel module. Getting it into the guest
is a separate concern from building the simulator, and it is the part most easily overlooked:

**1. Orchestration only *loads* the driver.** `CorundumLinuxHost` is a thin subclass of the standard
Linux host that appends `"mqnic"` to its list of drivers:

```python
class CorundumLinuxHost(sys_host.LinuxHost):
    def __init__(self, sys) -> None:
        super().__init__(sys)
        self.drivers.append("mqnic")
```

That makes the guest load the module at runtime. It does **not** put the module into the image.

**2. This repo builds and installs the module.** Two Makefile targets handle that:

```sh
make driver                                  # build mqnic.ko (+ corundum/utils) against $(KDIR)
make driver-install KDIR=... KVER=...        # install into /lib/modules/$(KVER)/extra + depmod -a
```

Both are meant to run **inside the image being built**, not on your host — `driver-install` writes
straight into `/lib/modules`. `KDIR` defaults to `/lib/modules/$(uname -r)/build` and `KVER` to
`$(uname -r)`, which is right when the module is built on the machine that will run it, and wrong
during image provisioning (see below).

**3. `simbricks/image-builder` drives this during an image build.** The
[image-builder](https://github.com/simbricks/image-builder) harness runs an ordered list of shell
stages inside the guest while building a disk image. Its `examples/corundum/install-mqnic.sh` stage
clones this repository in the guest, initializes the submodule, and calls `make driver-install`:

```sh
KDIR=$(ls -d /lib/modules/*/build | sort -V | tail -1)
KVER=$(basename "$(dirname "$KDIR")")

git clone https://github.com/simbricks/component-corundum.git /tmp/component-corundum
git -C /tmp/component-corundum submodule update --init

make -C /tmp/component-corundum driver-install KDIR="$KDIR" KVER="$KVER"
echo mqnic > /etc/modules-load.d/simbricks-mqnic.conf   # autoload on boot
```

Append the stage to an image build to get an image that works with Corundum:

```sh
make image EXTRA_SCRIPTS="examples/corundum/install-mqnic.sh"
```

Note that the stage derives `KDIR` from `/lib/modules/*/build` rather than from `uname -r`: the
driver must be built against **the kernel the image will boot**, but during provisioning the guest is
still running the cloud image's own kernel, so `uname -r` names the wrong one. This is also why the
build runs in-guest at image-build time instead of being shipped as a prebuilt `.ko` — an
out-of-tree module is tied to the exact kernel it was compiled against.

The script also relies on `git` already being present in the base image; it only installs
`build-essential` itself.

**4. The resulting image is what a virtual prototype must reference.** In the example under
[simbricks-examples/corundum](https://github.com/simbricks/simbricks-examples/tree/main/corundum),
`system.DistroDiskImage(syst, "base")` resolves to the runner's `base` image, and that image is
expected to have gone through the stage above. If it did not, the hosts boot but the NIC never comes
up.

## Local development

The Makefile targets are deliberately split so that, while working on this repo, you can build and
test the adapter or the Python packages **directly** — without going through the conda packaging
defined here. Install any *other* SimBricks dependencies from the conda channel and iterate on just
the piece you are changing.

### Adapter

```sh
# Verilate Corundum and build the adapter binary (adapter/corundum_simbricks_adapter).
# Point the SimBricks include/lib dirs at your env (e.g. your conda prefix) so it can link.
make corundum-build \
    SIMBRICKS_INC_DIR="$CONDA_PREFIX/include" \
    SIMBRICKS_LIB_DIR="$CONDA_PREFIX/lib"

# Install it as $(PREFIX)/bin/simb_corundum (builds first if needed).
make corundum-install PREFIX="$PWD/out"

# Reset the build (verilator output, adapter binary, python dists).
make clean
```

### Python packages

```sh
# Editable installs — iterate on the python code without reinstalling.
# The system package is installed first so the simulation package's imports resolve.
make corundum-python-develop
```

## Make target reference

| Target | Description |
|---|---|
| `all` (default) | Build all conda packages (alias for `conda-packages`). |
| `conda-packages` | Build all three conda packages in dependency order. |
| `corundum-sys-py-conda` | Build the `simbricks-corundum-sys-py` conda package. |
| `corundum-sim-rtl-py-conda` | Build the `simbricks-corundum-sim-rtl-py` conda package (builds `corundum-sys-py-conda` first). |
| `corundum-sim-rtl-bin-conda` | Build the `simbricks-corundum-sim-rtl-bin` conda package. |
| `corundum-build` | Verilate Corundum and build the adapter binary. |
| `adapter` | Backward-compatible alias for `corundum-build`. |
| `corundum-install` | Install the adapter into `$(PREFIX)/bin/simb_corundum`. |
| `driver` | Build the out-of-tree `mqnic` module and `corundum/utils` against `$(KDIR)`. |
| `driver-install` | Install `mqnic.ko` into `/lib/modules/$(KVER)/extra` and run `depmod`. Runs in the guest during an image build. |
| `corundum-python-develop` | Editable (`pip install -e`) installs of both python packages. |
| `clean` | Remove the verilator output, the adapter binary, `out/` and the python `dist/` dirs. |

### Useful variables

| Variable | Default | Purpose |
|---|---|---|
| `PREFIX` | `$(CURDIR)/out` | Install prefix for `corundum-install`. |
| `SIMBRICKS_INC_DIR` | `$(PREFIX)/include` | SimBricks headers for the adapter build. |
| `SIMBRICKS_LIB_DIR` | `$(PREFIX)/lib` | SimBricks static libs the adapter links against. |
| `KDIR` | `/lib/modules/$(uname -r)/build` | Kernel build tree the `mqnic` module is compiled against. |
| `KVER` | `$(uname -r)` | Kernel version whose module tree `driver-install` writes into. |
| `VERILATOR` | `verilator` | Verilator binary used to compile the RTL. |
| `PYTHON` | `python` | Interpreter used for `corundum-python-develop`. |
| `SIMB_CONDA_CHANNEL` | `-c https://conda.simbricks.io/latest` | Channel searched by `conda build` for external SimBricks deps. |
| `OUTPUT_FOLDER` | *(unset)* | If set, passed to `conda build --output-folder`. |

## Using it in a virtual prototype

With the packages installed, the Corundum classes are imported from the shared
`simbricks.components.corundum` namespace and wired up like any other SimBricks component:

```python
from simbricks.orchestration import system
from simbricks.orchestration.helpers import simulation as sim_helpers
from simbricks.components.qemu import simulation as qemu_sim
from simbricks.components.net.simulation import base as net_sim
from simbricks.components.corundum import system as corundum_sys
from simbricks.components.corundum import simulation as corundum_sim

syst = system.System("Corundum-Example")

host = corundum_sys.CorundumLinuxHost(syst)
host.add_disk(system.DistroDiskImage(syst, "base"))  # must contain the mqnic driver
host.add_disk(system.LinuxConfigDiskImage(syst, host))

nic = corundum_sys.CorundumNIC(syst)
nic.add_ipv4("10.0.0.1")
host.connect_pcie_dev(nic)

sim = sim_helpers.simple_simulation(
    syst,
    compmap={
        system.FullSystemHost: qemu_sim.QemuSim,
        corundum_sys.CorundumNIC: corundum_sim.CorundumVerilatorNICSim,
        system.EthSwitch: net_sim.SwitchNet,
    },
)
```

A complete, runnable experiment lives in
[simbricks-examples/corundum](https://github.com/simbricks/simbricks-examples/tree/main/corundum).

## Versioning

`conda-recipes/conda_build_config.yaml`'s `simbricks_version` is the single source of truth for the
conda package versions built here, and for the `==` pins between them (`sim-rtl-bin` → `sim-rtl-py` →
`sys-py`). It MUST stay in sync with the `version` in both `corundum_sys_py/pyproject.toml` and
`corundum_sim_rtl_py/pyproject.toml`, which drive the versions of the built wheels. External
dependencies (e.g. `simbricks-lib`) are not tied to it; they carry their own `>=` bounds since they
release independently.
