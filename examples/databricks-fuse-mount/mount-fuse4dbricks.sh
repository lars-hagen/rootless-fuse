#!/usr/bin/env bash
set -euo pipefail

: "${DATABRICKS_HOST:?Set DATABRICKS_HOST to your workspace URL.}"
: "${DATABRICKS_TOKEN:?Set DATABRICKS_TOKEN to a Databricks personal access token.}"

if [[ "$(id -u)" != "0" ]]; then
  echo "error: run this script as root inside a UML guest or rootless-fuse-shell." >&2
  exit 1
fi
for command_name in curl tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required." >&2
    exit 1
  fi
done

MOUNT_DIR="${FUSE4DBRICKS_MOUNT_DIR:-$HOME/databricks-mount}"
CACHE_DIR="${FUSE4DBRICKS_CACHE_DIR:-$HOME/.fuse4dbricks-cache}"
CACHE_GB="${FUSE4DBRICKS_CACHE_GB:-20}"
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/micromamba}"
MICROMAMBA="$HOME/.local/bin/micromamba"
ENV_NAME="dbmount"
ENV_PREFIX="$MAMBA_ROOT_PREFIX/envs/$ENV_NAME"

if [[ ! -x "$MICROMAMBA" ]]; then
  echo "==> Downloading micromamba"
  mkdir -p "$HOME/.local/bin"
  curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest |
    tar -xj -C "$HOME/.local/bin" bin/micromamba --strip-components=1
fi

export MAMBA_ROOT_PREFIX
export PATH="$HOME/.local/bin:$PATH"
eval "$("$MICROMAMBA" shell hook --shell bash)"

if [[ ! -x "$ENV_PREFIX/bin/python" ]]; then
  echo "==> Creating micromamba environment $ENV_NAME"
  micromamba create -n "$ENV_NAME" python=3.11 libfuse3 pkg-config \
    -c conda-forge --override-channels -y
fi
micromamba activate "$ENV_NAME"

# conda-forge installs fusermount3 under sbin rather than bin.
export PATH="$ENV_PREFIX/sbin:$PATH"
if ! command -v fusermount3 >/dev/null 2>&1; then
  echo "error: fusermount3 was not installed by the libfuse3 package." >&2
  exit 1
fi

if ! python -c 'import fuse4dbricks' >/dev/null 2>&1; then
  echo "==> Installing fuse4dbricks"
  python -m pip install fuse4dbricks
fi

mkdir -p "$MOUNT_DIR" "$CACHE_DIR"
echo "==> Starting fuse4dbricks"
fuse4dbricks \
  --workspace "$DATABRICKS_HOST" \
  --no-unified-auth \
  --single-principal \
  --disk-cache-dir "$CACHE_DIR" \
  --disk-cache-gb "$CACHE_GB" \
  "$MOUNT_DIR" &
fuse_pid=$!

auth_dir="$MOUNT_DIR/.auth"
for _ in {1..30}; do
  if [[ -d "$auth_dir" ]]; then
    break
  fi
  if ! kill -0 "$fuse_pid" 2>/dev/null; then
    wait "$fuse_pid" || true
    echo "error: fuse4dbricks exited before mounting $MOUNT_DIR." >&2
    exit 1
  fi
  sleep 1
done
if [[ ! -d "$auth_dir" ]]; then
  kill "$fuse_pid" 2>/dev/null || true
  echo "error: fuse4dbricks did not expose $auth_dir within 30 seconds." >&2
  exit 1
fi

printf '%s\n' "$DATABRICKS_TOKEN" > "$auth_dir/personal_access_token"
sleep 1

cat <<EOF
Databricks volumes mounted successfully.
Mount point: $MOUNT_DIR
Cache: $CACHE_DIR (up to ${CACHE_GB} GB)
fuse4dbricks PID: $fuse_pid

Processes must run inside this UML guest or direct-mode mount namespace to see the mount.
EOF
