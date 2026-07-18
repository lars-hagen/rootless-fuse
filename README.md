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

The final line is `DIRECT`, `UML`, or `IMPOSSIBLE`. Both `DIRECT` and `UML` exit successfully because both are actionable.

Install the selected path:

```bash
curl -fsSL https://raw.githubusercontent.com/lars-hagen/rootless-fuse/master/install.sh | bash
```

For `DIRECT`, the installer writes `~/.local/bin/rootless-fuse-shell` and downloads no kernel:

```bash
~/.local/bin/rootless-fuse-shell
# Start the FUSE mount and all consumers from this shell.
```

For `UML`, it downloads the kernel and VDE SLiRP toolchain, then writes `~/uml-init.sh` and `~/boot-uml.sh`:

```bash
~/boot-uml.sh
```

The boot wrapper prints the guest setup commands for proc, devtmpfs, `/dev/fuse`, `vec0`, routing, and DNS before starting UML. A FUSE mount created in either mode is visible only within that mount namespace or UML guest.

The worked example in [`examples/databricks-fuse-mount/`](examples/databricks-fuse-mount/) mounts Databricks Unity Catalog volumes through `fuse4dbricks`. Databricks TIKE motivated the UML fallback, but the probe and wrappers are generic.

## UML networking

UML uses hostfs and rootless VDE SLiRP networking:

```bash
~/linux-fuse.um mem=2G rootfstype=hostfs rootflags=/ rw init=~/uml-init.sh \
  'vec0:transport=vde,vnl=slirp://'
```

Linux removed `CONFIG_UML_NET`, `CONFIG_UML_NET_SLIRP`, and the legacy `eth0=` syntax in May 2025. The vector driver is the current interface, and its guest device is named `vec0`. The installer fetches `vde_plug`, `libvdeplug`, and `libvdeslirp` because no suitable packaged runtime is available.

Minimal guests may lack `ip`, so the printed setup uses `ifconfig` and `route`. hostfs preserves the real host user's ownership even for guest-root; DNS therefore uses a writable scratch file bind-mounted over `/etc/resolv.conf`.

`~/uml-init.sh` is PID-1-safe. PID 1 exiting always panics Linux with `Attempted to kill init!`, so the wrapper respawns a fresh shell instead of using `init=/bin/bash` directly.

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
