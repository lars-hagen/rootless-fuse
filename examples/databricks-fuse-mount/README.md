# Mount Databricks Unity Catalog volumes

This example mounts Databricks Unity Catalog volumes through [`fuse4dbricks`](https://pypi.org/project/fuse4dbricks/). Run it only after entering either a UML guest or the direct-mode `rootless-fuse-shell` created by the top-level installer. The script does not create a namespace itself.

## Requirements

- A working rootless FUSE shell with UID 0 inside it.
- `curl` and `tar`.
- A Databricks personal access token with the required API scope.
- `DATABRICKS_HOST` and `DATABRICKS_TOKEN` in the environment.

`fuse4dbricks` requires Python 3.11 or newer. Its `pyfuse3` dependency needs the conda-forge package named exactly `libfuse3`, plus `pkg-config`, to build. The script downloads a local static micromamba binary, creates a `dbmount` environment, and installs the Python package. It runs the micromamba Bash shell hook before activation; without the hook, activation does not select the environment and pip can use the wrong Python.

Conda-forge places `fusermount3` from `libfuse3` in the environment's `sbin/`, not `bin/`. The script adds that directory to `PATH` explicitly.

## Install

Add `--with-databricks` when running the top-level installer. It installs `mount-fuse4dbricks.sh` into `UML_INSTALL_DIR`, or `$HOME` by default:

```bash
curl -fsSL https://raw.githubusercontent.com/lars-hagen/rootless-fuse/master/install.sh | bash -s -- <direct|uml> --with-databricks
```

To download only this helper instead, use:

```bash
curl -fsSL https://raw.githubusercontent.com/lars-hagen/rootless-fuse/master/examples/databricks-fuse-mount/mount-fuse4dbricks.sh -o mount-fuse4dbricks.sh
chmod +x mount-fuse4dbricks.sh
```

## Run

```bash
export DATABRICKS_HOST="https://your-workspace.cloud.databricks.com"
export DATABRICKS_TOKEN="your-personal-access-token"
./mount-fuse4dbricks.sh
```

The default mount point is `~/databricks-mount`, with a 20 GB cache under `~/.fuse4dbricks-cache`. Override these settings with:

```bash
export FUSE4DBRICKS_MOUNT_DIR="$HOME/uc"
export FUSE4DBRICKS_CACHE_DIR="$HOME/.cache/fuse4dbricks"
export FUSE4DBRICKS_CACHE_GB=10
```

The underlying working invocation is:

```bash
fuse4dbricks --workspace "$DATABRICKS_HOST" --no-unified-auth \
  --single-principal --disk-cache-dir <cache-dir> --disk-cache-gb <size> <mountpoint>
```

## Authentication quirk

On first run, the mount may expose only `.auth/` even though a PAT is available. The token must be written after `fuse4dbricks` is running:

```bash
printf '%s\n' "$DATABRICKS_TOKEN" > <mountpoint>/.auth/personal_access_token
```

The script waits for `.auth/` and performs this step automatically.

## Permission denied on an owned volume

`fuse4dbricks` checks Unity Catalog's `effective-permissions` API before access. That endpoint can return an empty object for an owner without an explicit grant, which `fuse4dbricks` interprets as no access. Add an explicit grant for your user:

```bash
databricks grants update volume <catalog>.<schema>.<volume> --json '{
  "changes": [{
    "principal": "<your-databricks-email>",
    "add": ["READ_VOLUME", "WRITE_VOLUME"]
  }]
}'
```

Restart the mount and write the token again after changing the grant.

## Performance guidance

Previously read data is served from the local disk cache, so repeat reads are fast. Cold access depends on the network path to Databricks. Avoid many-small-files workloads such as extracting archives, installing packages, or creating `node_modules` directly on the mount; each file can require separate API and object-storage operations. Work on local scratch storage and copy finished artifacts to the volume.
