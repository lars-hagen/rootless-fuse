# Rootless FUSE with a UML fallback

Use FUSE in unprivileged Linux containers without requiring changes to the host. The project probes the container and chooses the lightest path that works:

- **Direct** uses the host kernel through an unprivileged user and mount namespace.
- **UML** boots a User Mode Linux kernel when the host withholds `/dev/fuse` or blocks namespaces and device creation.
- **Impossible** reports a specific blocker when the x86_64 UML fallback cannot be installed.

See [the architecture guide](docs/architecture.md) for the device, namespace, and `nodev` details.

## Quickstart

Probe without installing:

```bash
curl -fsSL https://raw.githubusercontent.com/lars-hagen/rootless-fuse/master/probe.sh | bash
```

The final line is `DIRECT`, `UML`, or `IMPOSSIBLE`. Both `DIRECT` and `UML` exit successfully because both are actionable. `install.sh` does not probe on its own, pass it the mode the probe recommended:

```bash
curl -fsSL https://raw.githubusercontent.com/lars-hagen/rootless-fuse/master/install.sh | bash -s -- direct
# or
curl -fsSL https://raw.githubusercontent.com/lars-hagen/rootless-fuse/master/install.sh | bash -s -- uml
```

Add the optional Databricks mount helper in either mode:

```bash
curl -fsSL https://raw.githubusercontent.com/lars-hagen/rootless-fuse/master/install.sh | bash -s -- direct --with-databricks
curl -fsSL https://raw.githubusercontent.com/lars-hagen/rootless-fuse/master/install.sh | bash -s -- uml --with-databricks
```

For `direct`, the installer writes `~/.local/bin/rootless-fuse-shell` and downloads no kernel:

```bash
~/.local/bin/rootless-fuse-shell
# Start the FUSE mount and all consumers from this shell.
```

For `uml`, it downloads the kernel and VDE SLiRP toolchain, then writes `~/uml-init.sh` and `~/boot-uml.sh`:

```bash
~/boot-uml.sh
```

`uml-init.sh` mounts proc and devtmpfs, creates `/dev/fuse`, and brings up `vec0` networking and DNS automatically before handing you a shell, no manual setup needed. A FUSE mount created in either mode is visible only within that mount namespace or UML guest.

The worked example in [`examples/databricks-fuse-mount/`](examples/databricks-fuse-mount/) mounts Databricks Unity Catalog volumes through `fuse4dbricks`. Databricks TIKE motivated the UML fallback, but the probe and wrappers are generic.

## UML networking

UML uses hostfs and rootless VDE SLiRP networking. This is what `boot-uml.sh` runs under the hood, use the wrapper rather than this directly, it also checks `mem=` against available host memory before booting (see below):

```bash
~/linux-fuse.um mem=2G rootfstype=hostfs rootflags=/ rw init=~/uml-init.sh \
  'vec0:transport=vde,vnl=slirp://'
```

Linux removed `CONFIG_UML_NET`, `CONFIG_UML_NET_SLIRP`, and the legacy `eth0=` syntax in May 2025. The vector driver is the current interface, and its guest device is named `vec0`. The installer fetches `vde_plug`, `libvdeplug`, and `libvdeslirp` because no suitable packaged runtime is available.

Minimal guests may lack `ip`, so the printed setup uses `ifconfig` and `route`. hostfs preserves the real host user's ownership even for guest-root; DNS therefore uses a writable scratch file bind-mounted over `/etc/resolv.conf`.

`~/uml-init.sh` is PID-1-safe. PID 1 exiting always panics Linux with `Attempted to kill init!`, so the wrapper respawns a fresh shell instead of using `init=/bin/bash` directly.

UML backs guest RAM with a real mmap'd file on `$TMPDIR` (or `/dev/shm` if unset), paged in lazily as the guest touches memory. Containers commonly cap `/dev/shm` at 64M, far below the 2G default, and a guest that boots fine can still crash with a host bus error and a full kernel panic hours later once it runs out of room there. `boot-uml.sh` checks available space (filesystem and cgroup memory limit, whichever is tighter) against `mem=` before booting and refuses to start if it looks insufficient:

```bash
TMPDIR=/tmp ~/boot-uml.sh          # point at a roomier directory
UML_MEMORY=768M ~/boot-uml.sh      # or ask for less memory
UML_ALLOW_MEMORY_OVERCOMMIT=1 ~/boot-uml.sh   # boot anyway, at your own risk
```

## Build workflows

### UML kernel

Run **Build UML kernel** from GitHub Actions. Its inputs are:

- `kernel_series`: Linux 6.18 by default, or 6.12 as a fallback.
- `kernel_version`: `latest-lts` or an exact point release in the selected series.
- `base_image`: build container and target glibc, defaulting to `amazonlinux:2023`.
- `extra_configs`: space-separated Kconfig overrides.
- `release_tag`: optional unique tag for a custom rebuild.

The workflow applies and verifies these settings after `olddefconfig`:

```text
CONFIG_FUSE_FS=y
CONFIG_HOSTFS=y
CONFIG_CUSE=y
CONFIG_UML_NET_VECTOR=y
```

It compiles with `KCFLAGS=-O3`. Upstream `ARCH=um` supports x86_64 hosts only; AArch64 UML is not implemented. The default release tag is `uml-vVERSION-amazonlinux-2023-x86_64` and contains:

- `linux-VERSION-x86_64-amazonlinux-2023`
- `linux.sha256`
- `.config`
- `release-notes.md`

The weekly update workflow runs at `17 9 * * 1`, compares the Linux 6.18 series on kernel.org with published assets, and triggers a default build only for a missing point release.

### VDE SLiRP toolchain

Run **Build VDE SLiRP networking toolchain** to build the pinned five-stage VDE and SLiRP stack against the selected base image. The default release tag is `vde-net-x86_64-amazonlinux-2023` and contains:

- `vde-slirp-net-x86_64-amazonlinux-2023.tar.gz`
- `vde-slirp-net.sha256`
- `release-notes.md`

The installer resolves the latest matching UML kernel through the GitHub releases API using Python, then fetches this fixed networking release. It does not require the GitHub CLI.
