# Architecture

Rootless FUSE has three outcomes. The probe selects the lightest actionable one.

## Decision tree

1. **Direct**. A usable `/dev/fuse` exists, or can be created inside an unprivileged user and mount namespace, and `unshare --user --map-root-user` works. Commands run in that namespace and use the host kernel directly.
2. **UML**. Direct mode cannot obtain both a user namespace and `/dev/fuse`, but an x86_64 UML kernel and its networking tools can be downloaded. User Mode Linux provides the guest with its own FUSE device and capability model.
3. **Impossible**. The x86_64-only UML fallback cannot run, or the files needed to install it cannot be fetched. The probe exits nonzero and reports the concrete reason.

## Why direct FUSE fails in containers

Containers share the host kernel. Their device view is assembled by the runtime, so an otherwise normal Linux filesystem can omit `/dev/fuse`. Creating the device node requires permission and a filesystem that permits devices. A `nodev` mount blocks a new device even when `mknod` runs as namespace-root.

An unprivileged user namespace maps the caller to UID 0 inside that namespace and grants capabilities scoped to it. A paired mount namespace then permits mounts without host-wide `CAP_SYS_ADMIN`. Hosts can disable this facility through `kernel.unprivileged_userns_clone`, user-namespace limits, seccomp, or container-runtime policy. That is distinct from the case where the namespace works but `nodev` prevents `/dev/fuse` creation, so `probe.sh` tests both independently.

Mounts remain private to their mount namespace. Start an interactive `rootless-fuse-shell`, or launch the mount and every consumer as descendants of one wrapper invocation.

## Why UML works

User Mode Linux is a Linux kernel compiled to run as an ordinary Linux process. The host sees an unprivileged process, not a request to mount FUSE or create a host device. Inside the guest, UML supplies its own `/dev`, capabilities, namespaces, and FUSE implementation. This separates the guest's device policy from the container host's policy.

The guest uses hostfs for its root filesystem and VDE SLiRP for rootless outbound networking. Current upstream kernels use `CONFIG_UML_NET_VECTOR` and the command line `vec0:transport=vde,vnl=slirp://`. The legacy `CONFIG_UML_NET`, `CONFIG_UML_NET_SLIRP`, and `eth0=` syntax were removed in May 2025 by Linux commit `e619e18ed462`; the old boot argument is silently ignored.

UML is heavier than direct mode and upstream `ARCH=um` supports x86_64 hosts only. It is therefore a fallback, not the default.
