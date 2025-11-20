# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Backup existing repo if present

if [ -d "$SCRIPT_DIR/repo" ]; then
  idx=1
  while [ -d "$SCRIPT_DIR/repo.backup${idx}" ]; do
    idx=$((idx + 1))
  done
  mv "$SCRIPT_DIR/repo" "$SCRIPT_DIR/repo.backup${idx}"
fi

# Make new repo directory
mkdir "$SCRIPT_DIR/repo"

# Rebuild libkqueue into /repo/pool (with your updated libkqueue builder)
docker build -t libkqueue-builder:arm64 -f libkqueue/Dockerfile.arm64.libkqueue libkqueue
docker run --rm -v "$SCRIPT_DIR/repo:/repo" libkqueue-builder:arm64

# Rebuild the harvested repo (this will also regenerate Packages & Release)
docker build -t fr-harvester-arm64:24.04 -f harvest/Dockerfile.arm64.harvester harvest
docker run --rm -v "$SCRIPT_DIR/repo:/repo" -v "$SCRIPT_DIR/repo:/seed" fr-harvester-arm64:24.04
