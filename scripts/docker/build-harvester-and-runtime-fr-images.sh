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
  echo "Usage: $0 [extra-packages-repo] [harvester-image] [runtime-image]" >&2
  echo "  extra-packages-repo: Absolute path to fr-extra-packages repo (auto-detects if omitted)" >&2
  echo "  harvester-image:     Optional custom harvester image name" >&2
  echo "  runtime-image:       Optional custom runtime image name" >&2
  exit 1
}

# Parse arguments

if [ -d "$PACKAGING_REPO" ]; then
  # Auto-detect packaging repo (no .deb check)
  FR_EXTRA_PACKAGES_REPO="$(cd "$SCRIPT_DIR/packaging" && pwd)"
  echo "[INFO] Auto-detected extra-packages repo at: $FR_EXTRA_PACKAGES_REPO"

  # Allow optional harvester/runtime image names
  HARVESTER_IMAGE="${1:-freeradius-deb-harvester:ubuntu24-arm64}"
  RUNTIME_IMAGE="${2:-freeradius-server:ubuntu24-arm64}"

else
  # User override mode
  if [ "$#" -lt 1 ]; then
    usage
  fi

  FR_EXTRA_PACKAGES_REPO="$1"

  case "$FR_EXTRA_PACKAGES_REPO" in
    /*) ;;  # absolute OK
    *) echo "ERROR: FR_EXTRA_PACKAGES_REPO must be absolute." >&2; exit 1;;
  esac

  if [ ! -d "$FR_EXTRA_PACKAGES_REPO" ]; then
    echo "ERROR: FR_EXTRA_PACKAGES_REPO directory does not exist: $FR_EXTRA_PACKAGES_REPO" >&2
    exit 1
  fi

  HARVESTER_IMAGE="${2:-freeradius-deb-harvester:ubuntu24-arm64}"
  RUNTIME_IMAGE="${3:-freeradius-server:ubuntu24-arm64}"
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

# ...existing code...

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
echo "✅ Done."
echo "   Harvester image: ${HARVESTER_IMAGE}"
echo "   Runtime image:   ${RUNTIME_IMAGE}"
echo "   Harvested debs:  ${HARVESTED_DIR}/"
