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

# UML backs guest RAM with a real mmap'd file in TMPDIR or one of the fallback
# directories below. It is paged in lazily as the guest touches memory, so a
# guest that boots fine can
# still crash with a host bus error and a full kernel panic hours later, once
# it touches enough pages to exceed whatever space is actually available.
# Containers commonly cap /dev/shm at 64M, far below a 2G guest, and that
# panic kills the guest and loses the session, so this fails closed by
# default instead of only warning. tmpfs pages are also charged against the
# container's cgroup memory limit, so a roomy filesystem alone is not
# sufficient, whichever constraint (filesystem or cgroup) is tighter wins.
mem_bytes() {
  local raw="$1"
  [[ "$raw" =~ ^[0-9]+[KkMmGg]?$ ]] || return 1
  local n="${raw%[KkMmGg]}" unit="${raw: -1}"
  case "$unit" in
    [Gg]) echo $((n * 1024 * 1024 * 1024)) ;;
    [Mm]) echo $((n * 1024 * 1024)) ;;
    [Kk]) echo $((n * 1024)) ;;
    *) echo "$n" ;;
  esac
}

available_bytes() {
  local shm_dir="$1" avail_bytes="" avail_kb cgroup_avail="" cg_max cg_cur

  if [[ -d "$shm_dir" ]] \
    && avail_kb="$(LC_ALL=C df -Pk "$shm_dir" 2>/dev/null | awk 'NR==2 {print $4}')" \
    && [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
    avail_bytes=$((avail_kb * 1024))
  fi

  if [[ -r /sys/fs/cgroup/memory.max && -r /sys/fs/cgroup/memory.current ]]; then
    cg_max="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
    cg_cur="$(cat /sys/fs/cgroup/memory.current 2>/dev/null || true)"
    [[ "$cg_max" =~ ^[0-9]+$ && "$cg_cur" =~ ^[0-9]+$ ]] && cgroup_avail=$((cg_max - cg_cur))
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes && -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
    cg_max="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)"
    cg_cur="$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || true)"
    # cgroup v1 signals "unlimited" with a huge sentinel rather than a
    # keyword; anything above 1T is treated as no real constraint.
    if [[ "$cg_max" =~ ^[0-9]+$ && "$cg_cur" =~ ^[0-9]+$ && "$cg_max" -lt $((1024 * 1024 * 1024 * 1024)) ]]; then
      cgroup_avail=$((cg_max - cg_cur))
    fi
  fi
  if [[ -n "$cgroup_avail" ]] && { [[ -z "$avail_bytes" ]] || (( cgroup_avail < avail_bytes )); }; then
    avail_bytes="$cgroup_avail"
  fi

  echo "$avail_bytes"
}

human_bytes() {
  local bytes="$1"
  if (( bytes >= 1024 * 1024 * 1024 )); then
    echo "$((bytes / 1024 / 1024 / 1024))G"
  else
    echo "$((bytes / 1024 / 1024))M"
  fi
}

if need_bytes="$(mem_bytes "$UML_MEMORY")"; then
  # Headroom beyond the raw guest RAM request: UML's own bookkeeping and
  # TT/SKAS overhead use a bit more than mem= alone.
  mem_check_margin=$((64 * 1024 * 1024))
  if [[ "${UML_TMPDIR_AUTO:-}" == "0" ]]; then
    shm_dir="${TMPDIR:-/dev/shm}"
    avail_bytes="$(available_bytes "$shm_dir")"
  else
    candidates=()
    [[ -n "${TMPDIR:-}" ]] && candidates+=("$TMPDIR")
    for candidate in /dev/shm /tmp; do
      duplicate=""
      for existing in "${candidates[@]}"; do
        [[ "$candidate" == "$existing" ]] && duplicate=1
      done
      [[ -z "$duplicate" ]] && candidates+=("$candidate")
    done

    checked_dirs=()
    checked_avails=()
    selected_index=""
    for candidate in "${candidates[@]}"; do
      candidate_avail="$(available_bytes "$candidate")"
      checked_dirs+=("$candidate")
      checked_avails+=("$candidate_avail")
      if [[ -n "$candidate_avail" ]] && (( candidate_avail >= need_bytes + mem_check_margin )); then
        selected_index=$((${#checked_dirs[@]} - 1))
        break
      fi
    done

    if [[ -n "$selected_index" ]]; then
      avail_bytes="${checked_avails[selected_index]}"
      if (( selected_index > 0 )); then
        skipped=""
        for ((i = 0; i < selected_index; i++)); do
          [[ -n "$skipped" ]] && skipped+=", "
          skipped+="${checked_dirs[i]} only has $(human_bytes "${checked_avails[i]:-0}") free"
        done
        export TMPDIR="${checked_dirs[selected_index]}"
        echo "==> $skipped, using $TMPDIR ($(human_bytes "$avail_bytes") free) for UML's RAM-backing file instead." >&2
      fi
    elif [[ "${UML_ALLOW_MEMORY_OVERCOMMIT:-}" == "1" ]]; then
      checked=""
      for ((i = 0; i < ${#checked_dirs[@]}; i++)); do
        [[ -n "$checked" ]] && checked+=", "
        checked+="${checked_dirs[i]}: $(human_bytes "${checked_avails[i]:-0}") free"
      done
      echo "warning: checked $checked; none has enough room for mem=$UML_MEMORY plus headroom. Booting anyway because UML_ALLOW_MEMORY_OVERCOMMIT=1 is set." >&2
      avail_bytes=""
    else
      {
        echo "error: no checked directory has enough room for UML's RAM-backing file:"
        for ((i = 0; i < ${#checked_dirs[@]}; i++)); do
          echo "  ${checked_dirs[i]}: $(human_bytes "${checked_avails[i]:-0}") free"
        done
        cat <<EOF
mem=$UML_MEMORY needs that much plus headroom. Booting anyway risks a host bus
error and a full kernel panic mid-session, killing the guest.

Fix by pointing UML at another roomier directory, or lowering the memory request:
  TMPDIR=/path/to/roomy/directory $SELF_DIR/boot-uml.sh
  UML_MEMORY=768M $SELF_DIR/boot-uml.sh

Or boot anyway at your own risk:
  UML_ALLOW_MEMORY_OVERCOMMIT=1 $SELF_DIR/boot-uml.sh
EOF
      } >&2
      exit 1
    fi
  fi

  if [[ -n "$avail_bytes" ]] && (( avail_bytes < need_bytes + mem_check_margin )); then
    if [[ "${UML_ALLOW_MEMORY_OVERCOMMIT:-}" == "1" ]]; then
      echo "warning: only ${avail_bytes}B available toward mem=$UML_MEMORY plus headroom. Booting anyway because UML_ALLOW_MEMORY_OVERCOMMIT=1 is set." >&2
    else
      cat >&2 <<EOF
error: only $((avail_bytes / 1024 / 1024))M is available for UML's RAM-backing
file, but mem=$UML_MEMORY needs that much plus headroom. Booting anyway risks
a host bus error and a full kernel panic mid-session, killing the guest.

Fix by pointing UML at a roomier directory, or lowering the memory request:
  TMPDIR=/tmp $SELF_DIR/boot-uml.sh
  UML_MEMORY=768M $SELF_DIR/boot-uml.sh

Or boot anyway at your own risk:
  UML_ALLOW_MEMORY_OVERCOMMIT=1 $SELF_DIR/boot-uml.sh
EOF
      exit 1
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
