#!/usr/bin/env bash
set -euo pipefail

REPO="${ROOTLESS_FUSE_REPO:-lars-hagen/rootless-fuse}"

echo "Rootless FUSE capability probe"
echo "=============================="

arch="$(uname -m)"
echo "Host architecture: $arch"

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
  # A character device node existing is not sufficient: verify it is
  # actually the FUSE device (10:229, not some other node squatting on the
  # path) and that it can be opened, since device-cgroup policy or file
  # permissions can deny access even when the node itself looks right.
  dev_major="$((0x$(stat -c '%t' /dev/fuse 2>/dev/null || echo 0)))"
  dev_minor="$((0x$(stat -c '%T' /dev/fuse 2>/dev/null || echo 0)))"
  if [[ "$dev_major" == "10" && "$dev_minor" == "229" ]] && ( : <>/dev/fuse ) 2>/dev/null; then
    fuse_ok=true
    echo "/dev/fuse: existing character device (10:229), opened successfully"
  else
    echo "/dev/fuse: character device exists but is not a usable FUSE device (major:minor $dev_major:$dev_minor, or open denied)"
  fi
elif [[ -e /dev/fuse ]]; then
  echo "/dev/fuse: exists but is not a character device"
else
  echo "/dev/fuse: missing"
  if command -v unshare >/dev/null 2>&1; then
    # Mirrors what the installed DIRECT wrapper does: mount a private
    # devtmpfs first (avoids mutating the host's real /dev, and survives
    # a nodev restriction on the host's own /dev mount since this is a
    # fresh mount entirely), falling back to a plain mknod only if that
    # private mount is not permitted.
    mknod_error="$(unshare --user --map-root-user --mount bash -c '
      set -e
      mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
      if [ -c /dev/fuse ]; then exit 0; fi
      mknod /dev/fuse c 10 229
      test -c /dev/fuse
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

echo "Direct mode is unavailable; checking the UML fallback."
if [[ "$arch" != "x86_64" ]]; then
  echo "UML fallback: unavailable. Upstream Linux ARCH=um supports x86_64 only."
  echo "IMPOSSIBLE"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "UML fallback cannot be installed because curl is unavailable."
  echo "IMPOSSIBLE"
  exit 1
fi
releases_json="$(curl -fsSL --max-time 15 "https://api.github.com/repos/$REPO/releases" 2>/dev/null || true)"
if [[ -z "$releases_json" ]]; then
  echo "UML fallback cannot be installed because GitHub release downloads are unreachable."
  echo "IMPOSSIBLE"
  exit 1
fi
if ! grep -qE '"name": *"linux-[^"]*-x86_64-amazonlinux-2023"' <<<"$releases_json"; then
  echo "UML fallback cannot be installed: no linux-*-x86_64-amazonlinux-2023 kernel release asset exists yet."
  echo "IMPOSSIBLE"
  exit 1
fi
if ! curl -fsSL --max-time 15 -r 0-0 -o /dev/null \
  "https://github.com/$REPO/releases/download/vde-net-x86_64-amazonlinux-2023/vde-slirp-net-x86_64-amazonlinux-2023.tar.gz"; then
  echo "UML fallback cannot be installed: the vde-net-x86_64-amazonlinux-2023 release asset was not found."
  echo "IMPOSSIBLE"
  exit 1
fi

if [[ "$userns_ok" == false ]]; then
  echo "User namespaces are blocked; UML runs as an ordinary host process and does not require them."
else
  echo "User namespaces work, but the container prevents creation of a usable /dev/fuse device."
fi
echo "UML"
