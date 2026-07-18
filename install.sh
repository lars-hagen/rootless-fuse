#!/usr/bin/env bash
set -euo pipefail

REPO="${ROOTLESS_FUSE_REPO:-lars-hagen/rootless-fuse}"
DEST="${UML_INSTALL_DIR:-$HOME}"
LOCAL_BIN="${ROOTLESS_FUSE_BIN_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
probe_file=""

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "error: upstream Linux ARCH=um and the published fallback support x86_64 only (detected $(uname -m))." >&2
  exit 1
fi

cleanup() {
  if [[ -n "$probe_file" ]]; then
    rm -f "$probe_file"
  fi
}
trap cleanup EXIT

if [[ -n "${ROOTLESS_FUSE_PROBE:-}" ]]; then
  probe_cmd=(bash "$ROOTLESS_FUSE_PROBE")
elif [[ -f "$SCRIPT_DIR/probe.sh" ]]; then
  probe_cmd=(bash "$SCRIPT_DIR/probe.sh")
else
  if ! command -v curl >/dev/null 2>&1; then
    echo "error: probe.sh is not available locally and curl is unavailable." >&2
    exit 1
  fi
  probe_file="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/$REPO/master/probe.sh" -o "$probe_file"
  probe_cmd=(bash "$probe_file")
fi

set +e
probe_output="$("${probe_cmd[@]}" 2>&1)"
probe_status=$?
set -e
printf '%s\n' "$probe_output"
verdict="$(printf '%s\n' "$probe_output" | tail -n 1)"

if [[ "$verdict" == "IMPOSSIBLE" ]]; then
  echo "error: the capability probe found no actionable rootless FUSE path. See the specific reason above." >&2
  exit 1
fi
if ((probe_status != 0)); then
  echo "error: probe.sh failed before returning a valid verdict." >&2
  exit "$probe_status"
fi

if [[ "$verdict" == "DIRECT" ]]; then
  mkdir -p "$LOCAL_BIN"
  cat > "$LOCAL_BIN/rootless-fuse-shell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if (($# == 0)); then
  exec unshare --user --map-root-user --mount bash
fi
exec unshare --user --map-root-user --mount bash -c 'exec "$@"' bash "$@"
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

if [[ "$verdict" != "UML" ]]; then
  echo "error: probe.sh returned an unknown verdict: $verdict" >&2
  exit 1
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

if [[ -f "$SCRIPT_DIR/boot-uml.sh" ]]; then
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
