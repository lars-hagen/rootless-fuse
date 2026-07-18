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

# UML backs guest RAM with a real mmap'd file on this directory (defaults to
# /dev/shm if TMPDIR is unset, matching UML's own probe order). That file is
# paged in lazily as the guest touches memory, so a guest that boots fine can
# still panic with a host bus error hours later once it touches enough pages
# to exceed whatever space is actually available there. Containers commonly
# cap /dev/shm at 64M, far below a 2G guest, so check before booting instead
# of finding out mid-session.
mem_bytes() {
  local n="${1%[KkMmGg]}" unit="${1: -1}"
  case "$unit" in
    [Gg]) echo $((n * 1024 * 1024 * 1024)) ;;
    [Mm]) echo $((n * 1024 * 1024)) ;;
    [Kk]) echo $((n * 1024)) ;;
    *) echo "$1" ;;
  esac
}
shm_dir="${TMPDIR:-/dev/shm}"
if [[ -d "$shm_dir" ]]; then
  avail_kb="$(df -Pk "$shm_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$avail_kb" ]]; then
    avail_bytes=$((avail_kb * 1024))
    need_bytes="$(mem_bytes "$UML_MEMORY")"
    if (( avail_bytes < need_bytes )); then
      cat >&2 <<EOF
warning: $shm_dir has $((avail_bytes / 1024 / 1024))M free, but mem=$UML_MEMORY
needs up to that much for the guest's RAM backing file. The guest may boot
fine and then hit a host bus error later once it touches enough memory to
exceed what is actually available here.

Fix by pointing UML at a roomier directory, or lowering the memory request:
  TMPDIR=/tmp $SELF_DIR/boot-uml.sh
  UML_MEMORY=768M $SELF_DIR/boot-uml.sh
EOF
    fi
  fi
fi

cat >&2 <<EOF
The default $UML_INIT (written by install.sh) mounts proc/devtmpfs,
creates /dev/fuse, and brings up vec0 networking automatically before
handing you a shell. If you passed a custom UML_INIT that skips this,
see the "One-time boot setup" block in a stock uml-init.sh for the
commands to run yourself.
EOF

exec "$UML_KERNEL" "mem=$UML_MEMORY" rootfstype=hostfs rootflags=/ rw "init=$UML_INIT" \
  'vec0:transport=vde,vnl=slirp://'
