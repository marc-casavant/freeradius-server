#!/usr/bin/env bash
set -euo pipefail

############################################
# Usage / argument parsing
############################################

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /absolute/path/to/fr-extra-packages-repo" >&2
  exit 1
fi

FR_EXTRA_PACKAGES_REPO="$1"

# Require an absolute path (starts with /)
case "$FR_EXTRA_PACKAGES_REPO" in
  /*) ;;
  *)
    echo "ERROR: FR_EXTRA_PACKAGES_REPO must be an absolute path, got: $FR_EXTRA_PACKAGES_REPO" >&2
    exit 1
    ;;
esac

if [ ! -d "$FR_EXTRA_PACKAGES_REPO" ]; then
  echo "ERROR: FR_EXTRA_PACKAGES_REPO does not exist or is not a directory: $FR_EXTRA_PACKAGES_REPO" >&2
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

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
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
HARVESTER_IMAGE="freeradius-deb-harvester:ubuntu24-arm64"
RUNTIME_IMAGE="freeradius-server:ubuntu24-arm64"

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
