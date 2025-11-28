#!/usr/bin/env bash
set -euo pipefail

############################################
# Usage / argument parsing & auto-detect
############################################

# Always resolve script location for repo detection
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname "$SCRIPT_PATH")" >/dev/null 2>&1 && pwd)"
PACKAGING_REPO="$SCRIPT_DIR/packaging/repo"

# Usage message
usage() {
  echo "Usage: $0 [--extra-packages-repo <path>] [--harvester-image-name <name>] [--runtime-image-name <name>] [--log <logfile>]" >&2
  echo "  --extra-packages-repo <path>: Absolute path to fr-extra-packages repo (auto-detects if omitted)" >&2
  echo "  --harvester-image-name <name>: Optional custom harvester image name" >&2
  echo "  --runtime-image-name <name>:   Optional custom runtime image name" >&2
  echo "  --log <logfile>:               Optional log file to export build output" >&2
  exit 1
}

# Parse named arguments
FR_EXTRA_PACKAGES_REPO=""
HARVESTER_IMAGE="freeradius-deb-harvester:ubuntu24-arm64"
RUNTIME_IMAGE="freeradius-server:ubuntu24-arm64"
LOGFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --extra-packages-repo)
      if [[ -n "$2" ]]; then
        FR_EXTRA_PACKAGES_REPO="$2"
        shift 2
      else
        echo "ERROR: --extra-packages-repo requires a path argument" >&2
        usage
      fi
      ;;
    --harvester-image-name)
      if [[ -n "$2" ]]; then
        HARVESTER_IMAGE="$2"
        shift 2
      else
        echo "ERROR: --harvester-image-name requires a name argument" >&2
        usage
      fi
      ;;
    --runtime-image-name)
      if [[ -n "$2" ]]; then
        RUNTIME_IMAGE="$2"
        shift 2
      else
        echo "ERROR: --runtime-image-name requires a name argument" >&2
        usage
      fi
      ;;
    --log)
      if [[ -n "$2" ]]; then
        LOGFILE="$2"
        shift 2
      else
        echo "ERROR: --log requires a filename argument" >&2
        usage
      fi
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage
      ;;
  esac
done

# Auto-detect packaging repo if not provided
if [[ -z "$FR_EXTRA_PACKAGES_REPO" ]]; then
  if [ -d "$PACKAGING_REPO" ]; then
    FR_EXTRA_PACKAGES_REPO="$(cd "$SCRIPT_DIR/packaging" && pwd)"
    echo "[INFO] Auto-detected extra-packages repo at: $FR_EXTRA_PACKAGES_REPO"
  else
    echo "ERROR: --extra-packages-repo not provided and auto-detect failed." >&2
    usage
  fi
fi

# Validate repo path
case "$FR_EXTRA_PACKAGES_REPO" in
  /*) ;;  # absolute OK
  *) echo "ERROR: --extra-packages-repo must be absolute." >&2; exit 1;;
esac

if [ ! -d "$FR_EXTRA_PACKAGES_REPO" ]; then
  echo "ERROR: FR_EXTRA_PACKAGES_REPO directory does not exist: $FR_EXTRA_PACKAGES_REPO" >&2
  exit 1
fi

LOCALREPO="$FR_EXTRA_PACKAGES_REPO/repo"
if [ ! -d "$LOCALREPO" ]; then
  echo "ERROR: LOCALREPO directory not found: $LOCALREPO" >&2
  echo "       Make sure you ran the fr-extra-packages workflow to populate '$LOCALREPO'." >&2
  exit 1
fi

############################################
# Locate repo root (freeradius-server)
############################################

# scripts/docker → repo root = ../..
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Redirect output to logfile if specified
if [[ -n "$LOGFILE" ]]; then
  exec > >(tee "$LOGFILE") 2>&1
fi

echo "Running from REPO_ROOT: $REPO_ROOT"
echo "Using FR_EXTRA_PACKAGES_REPO: $FR_EXTRA_PACKAGES_REPO"
echo "Using LOCALREPO:         $LOCALREPO"
echo

cd "$REPO_ROOT"

############################################
# Config
############################################

HARVESTED_DIR="${HARVESTED_DIR:-fr-harvested-debs}"

PLATFORM="linux/arm64"

HARVESTER_DOCKERFILE="$REPO_ROOT/scripts/docker/build/ubuntu24/Dockerfile.ubuntu24.harvester"
RUNTIME_DOCKERFILE="$REPO_ROOT/scripts/docker/build/ubuntu24/Dockerfile.ubuntu24.runtime"

############################################
# Step 1: Build harvester image
############################################

echo "=== Step 1: Build harvester image (${HARVESTER_IMAGE}) ==="
echo "Using localrepo build context: ${LOCALREPO}"
docker buildx build \
  --platform "${PLATFORM}" \
  -t "${HARVESTER_IMAGE}" \
  -f "${HARVESTER_DOCKERFILE}" \
  --build-context "localrepo=${LOCALREPO}" \
  --no-cache \
  --load \
  "$REPO_ROOT"

############################################
# Step 2: Harvest debs
############################################

echo
echo "=== Step 2: Harvest debs into ./${HARVESTED_DIR} ==="
rm -rf "${HARVESTED_DIR}"
mkdir -p "${HARVESTED_DIR}"

docker run --rm \
  -v "$REPO_ROOT/${HARVESTED_DIR}:/out" \
  "${HARVESTER_IMAGE}" \
  bash -c '
    set -e
    echo "[harvester] Copying FreeRADIUS debs from /usr/local/src/repositories..."
    cp /usr/local/src/repositories/*.deb /out/
    echo "[harvester] Copying localrepo debs from /opt/localrepo..."
    find /opt/localrepo -type f -name "*.deb" -exec cp {} /out/ \;
    echo "[harvester] Done. Files in /out:"
    ls -1 /out
  '

############################################
# Step 3: Build runtime image
############################################

echo
echo "=== Step 3: Build runtime image (${RUNTIME_IMAGE}) from harvested debs ==="
docker buildx build \
  --platform "${PLATFORM}" \
  -t "${RUNTIME_IMAGE}" \
  -f "${RUNTIME_DOCKERFILE}" \
  --build-context "localrepo=./${HARVESTED_DIR}" \
  --no-cache \
  --load \
  "$REPO_ROOT"

echo
echo "   Harvester image: ${HARVESTER_IMAGE}"
echo "   Runtime image:   ${RUNTIME_IMAGE}"
echo "   Harvested debs:  ${HARVESTED_DIR}/"
