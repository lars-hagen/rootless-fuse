#!/usr/bin/env bash
set -euo pipefail

REPO="${ROOTLESS_FUSE_REPO:-lars-hagen/rootless-fuse}"

echo "Rootless FUSE capability probe"
echo "=============================="

arch="$(uname -m)"
echo "Host architecture: $arch"
if [[ "$arch" != "x86_64" ]]; then
  echo "UML fallback: unavailable. Upstream Linux ARCH=um supports x86_64 only."
  echo "IMPOSSIBLE"
  exit 1
fi

fuse_filesystem=false
if [[ -r /proc/filesystems ]]; then
  while IFS= read -r line; do
    if [[ "$line" == *fuse* ]]; then
      fuse_filesystem=true
      break
    fi
  done < /proc/filesystems
fi
if [[ "$fuse_filesystem" == true ]]; then
  echo "Kernel FUSE filesystem support: listed in /proc/filesystems"
else
  echo "Kernel FUSE filesystem support: not listed in /proc/filesystems"
fi

if command -v fusermount3 >/dev/null 2>&1; then
  echo "fusermount3: $(command -v fusermount3)"
else
  echo "fusermount3: not found"
fi
if command -v fusermount >/dev/null 2>&1; then
  echo "fusermount: $(command -v fusermount)"
else
  echo "fusermount: not found"
fi
if command -v python3 >/dev/null 2>&1; then
  echo "Python: $(python3 --version 2>&1)"
else
  echo "Python: python3 not found"
fi

fuse_ok=false
mknod_status=1
mknod_error=""
if [[ -c /dev/fuse ]]; then
  fuse_ok=true
  echo "/dev/fuse: existing character device"
elif [[ -e /dev/fuse ]]; then
  echo "/dev/fuse: exists but is not a character device"
else
  echo "/dev/fuse: missing"
  if command -v unshare >/dev/null 2>&1; then
    mknod_error="$(unshare --user --map-root-user --mount bash -c '
      mknod /dev/fuse c 10 229 || exit
      test -c /dev/fuse || exit
      rm -f /dev/fuse
    ' 2>&1)" && mknod_status=0 || mknod_status=$?
    if ((mknod_status == 0)); then
      fuse_ok=true
      echo "/dev/fuse creation in user namespace: working"
    else
      echo "/dev/fuse creation in user namespace: blocked"
      [[ -n "$mknod_error" ]] && printf '  %s\n' "$mknod_error"
    fi
  else
    echo "/dev/fuse creation in user namespace: not attempted because unshare is unavailable"
  fi
fi

userns_ok=false
if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user id >/dev/null 2>&1; then
  userns_ok=true
  echo "Unprivileged user namespace: working"
else
  echo "Unprivileged user namespace: blocked or unshare is unavailable"
fi

if [[ "$userns_ok" == true && "$fuse_ok" == true ]]; then
  echo "DIRECT"
  exit 0
fi

echo "Direct mode is unavailable; checking whether UML release downloads are reachable."
if ! command -v curl >/dev/null 2>&1; then
  echo "UML fallback cannot be installed because curl is unavailable."
  echo "IMPOSSIBLE"
  exit 1
fi
if ! curl -fsSL --max-time 15 "https://api.github.com/repos/$REPO/releases?per_page=1" >/dev/null; then
  echo "UML fallback cannot be installed because GitHub release downloads are unreachable."
  echo "IMPOSSIBLE"
  exit 1
fi

if [[ "$userns_ok" == false ]]; then
  echo "User namespaces are blocked; UML runs as an ordinary host process and does not require them."
else
  echo "User namespaces work, but the container prevents creation of a usable /dev/fuse device."
fi
echo "UML"
