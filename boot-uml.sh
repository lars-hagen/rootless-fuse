#!/usr/bin/env bash
set -euo pipefail

UML_KERNEL="${UML_KERNEL:-$HOME/linux-fuse.um}"
UML_INIT="${UML_INIT:-$HOME/uml-init.sh}"
VDE_NET="${VDE_NET:-$HOME/vde-net}"
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

cat >&2 <<'EOF'
After the guest shell appears, run inside UML:

  mount -t proc proc /proc
  mount -t devtmpfs devtmpfs /dev
  mknod /dev/fuse c 10 229 && chmod 666 /dev/fuse

  ifconfig lo up
  ifconfig vec0 10.0.2.15 netmask 255.255.255.0 up
  route add default gw 10.0.2.2 vec0
  mkdir -p /tmp && printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf
  mount --bind /tmp/resolv.conf /etc/resolv.conf

The resolv.conf bind mount avoids hostfs ownership checks on the host file.
EOF

exec "$UML_KERNEL" "mem=$UML_MEMORY" rootfstype=hostfs rootflags=/ rw "init=$UML_INIT" \
  'vec0:transport=vde,vnl=slirp://'
