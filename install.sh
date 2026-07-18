#!/usr/bin/env bash
set -euo pipefail

REPO="${ROOTLESS_FUSE_REPO:-lars-hagen/rootless-fuse}"
DEST="${UML_INSTALL_DIR:-$HOME}"
LOCAL_BIN="${ROOTLESS_FUSE_BIN_DIR:-$HOME/.local/bin}"
# Only trust a sibling script next to a real local install.sh (e.g. a git
# checkout). Under `curl | bash`, BASH_SOURCE[0] is empty and must never
# resolve to the caller's arbitrary current directory.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi

usage() {
  cat >&2 <<EOF
usage: install.sh <direct|uml>

Run probe.sh first to find out which mode your container supports:
  curl -fsSL https://raw.githubusercontent.com/$REPO/master/probe.sh | bash

Then install the mode it recommends:
  install.sh direct   # unprivileged namespace on the host kernel, no download
  install.sh uml      # boots a User Mode Linux kernel with its own /dev/fuse
EOF
}

verdict="${1:-${ROOTLESS_FUSE_MODE:-}}"
verdict="$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')"

if [[ "$verdict" != "DIRECT" && "$verdict" != "UML" ]]; then
  usage
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" && "$verdict" == "UML" ]]; then
  echo "error: the UML fallback supports x86_64 hosts only (detected $(uname -m))." >&2
  exit 1
fi

if [[ "$verdict" == "DIRECT" ]]; then
  mkdir -p "$LOCAL_BIN"
  cat > "$LOCAL_BIN/rootless-fuse-shell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Mount a private devtmpfs before doing anything else: a plain mount
# namespace does not isolate ordinary file creation under the host's real
# /dev, so mknod there either fails (nodev, permissions) or leaks a device
# node into the shared host /dev. A fresh devtmpfs is namespace-private and
# auto-populates every device the kernel currently exposes, /dev/fuse
# included if the fuse module is loaded, so nothing else under /dev breaks.
SETUP='mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
[ -c /dev/fuse ] || mknod /dev/fuse c 10 229 2>/dev/null || true
chmod 666 /dev/fuse 2>/dev/null || true
'

if (($# == 0)); then
  exec unshare --user --map-root-user --mount bash -c "$SETUP"'exec bash'
fi
exec unshare --user --map-root-user --mount bash -c "$SETUP"'exec "$@"' bash "$@"
EOF
  chmod +x "$LOCAL_BIN/rootless-fuse-shell"
  cat <<EOF

Direct mode installed. No kernel was downloaded.

Start an interactive rootless FUSE shell:
  $LOCAL_BIN/rootless-fuse-shell

Or run one command in the namespace:
  $LOCAL_BIN/rootless-fuse-shell command arg...
EOF
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: UML mode requires python3 to parse the GitHub releases API." >&2
  exit 1
fi
for command_name in curl tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: UML mode requires $command_name." >&2
    exit 1
  fi
done

echo "==> Installing UML mode into $DEST"
mkdir -p "$DEST" "$LOCAL_BIN"

echo "==> Resolving latest UML kernel release"
KERNEL_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases" | python3 -c '
import json, sys
for release in json.load(sys.stdin):
    for asset in release.get("assets", []):
        name = asset["name"]
        if name.startswith("linux-") and name.endswith("-x86_64-amazonlinux-2023"):
            print(asset["browser_download_url"])
            raise SystemExit
')"
if [[ -z "$KERNEL_URL" ]]; then
  echo "error: no linux-*-x86_64-amazonlinux-2023 release asset was found." >&2
  exit 1
fi
curl -fL "$KERNEL_URL" -o "$DEST/linux-fuse.um"
chmod +x "$DEST/linux-fuse.um"

echo "==> Downloading VDE SLiRP networking toolchain"
rm -rf "$DEST/vde-net" "$DEST/vde-net.tar.gz"
mkdir -p "$DEST/vde-net"
curl -fL "https://github.com/$REPO/releases/download/vde-net-x86_64-amazonlinux-2023/vde-slirp-net-x86_64-amazonlinux-2023.tar.gz" \
  -o "$DEST/vde-net.tar.gz"
tar -xzf "$DEST/vde-net.tar.gz" -C "$DEST/vde-net" --strip-components=1
rm -f "$DEST/vde-net.tar.gz"

echo "==> Writing $DEST/uml-init.sh"
cat > "$DEST/uml-init.sh" <<EOF
#!/bin/bash
# PID 1 must never exit or the kernel panics ("Attempted to kill init!").
# Respawn a fresh shell instead of letting one exit take the guest down.
export HOME="$HOME"
export USER="${USER:-$(id -un)}"
export PATH="$DEST/vde-net/bin:\$PATH"
export LD_LIBRARY_PATH="$DEST/vde-net/lib:\${LD_LIBRARY_PATH:-}"
cd "\$HOME" 2>/dev/null || cd /
while true; do
  bash --noprofile --norc
done
EOF
chmod +x "$DEST/uml-init.sh"

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/boot-uml.sh" ]]; then
  if [[ "$SCRIPT_DIR/boot-uml.sh" != "$DEST/boot-uml.sh" ]]; then
    cp "$SCRIPT_DIR/boot-uml.sh" "$DEST/boot-uml.sh"
  fi
else
  curl -fsSL "https://raw.githubusercontent.com/$REPO/master/boot-uml.sh" -o "$DEST/boot-uml.sh"
fi
chmod +x "$DEST/boot-uml.sh"

cat <<EOF

UML mode installed.

Boot the guest with:
  $DEST/boot-uml.sh
EOF
