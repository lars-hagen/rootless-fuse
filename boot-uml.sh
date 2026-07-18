#!/usr/bin/env bash
set -euo pipefail

# install.sh always writes this script into the same directory as the
# kernel, init wrapper, and VDE toolchain, so resolve relative to itself
# rather than $HOME. That makes UML_INSTALL_DIR overrides at install time
# work without also having to override these three at boot time.
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UML_KERNEL="${UML_KERNEL:-$SELF_DIR/linux-fuse.um}"
UML_INIT="${UML_INIT:-$SELF_DIR/uml-init.sh}"
VDE_NET="${VDE_NET:-$SELF_DIR/vde-net}"
UML_MEMORY="${UML_MEMORY:-2G}"

if [[ ! -x "$UML_KERNEL" ]]; then
  echo "error: UML kernel is not executable: $UML_KERNEL. Run install.sh first or set UML_KERNEL." >&2
  exit 1
fi
if [[ ! -x "$UML_INIT" ]]; then
  echo "error: UML init wrapper is not executable: $UML_INIT. Run install.sh first or set UML_INIT." >&2
  exit 1
fi
if [[ ! -x "$VDE_NET/bin/vde_plug" ]]; then
  echo "error: VDE SLiRP toolchain not found under $VDE_NET. Run install.sh first or set VDE_NET." >&2
  exit 1
fi

export PATH="$VDE_NET/bin:$PATH"
export LD_LIBRARY_PATH="$VDE_NET/lib:${LD_LIBRARY_PATH:-}"

cat >&2 <<EOF
The default $UML_INIT (written by install.sh) mounts proc/devtmpfs,
creates /dev/fuse, and brings up vec0 networking automatically before
handing you a shell. If you passed a custom UML_INIT that skips this,
see the "One-time boot setup" block in a stock uml-init.sh for the
commands to run yourself.
EOF

exec "$UML_KERNEL" "mem=$UML_MEMORY" rootfstype=hostfs rootflags=/ rw "init=$UML_INIT" \
  'vec0:transport=vde,vnl=slirp://'
