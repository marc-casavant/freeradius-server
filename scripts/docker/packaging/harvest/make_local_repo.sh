#!/usr/bin/env bash
set -euo pipefail

REPO=/repo
POOL=pool

# Ensure target directories exist:
# dists/stable/main/binary-arm64 is where APT expects index files
mkdir -p "$REPO/$POOL" "$REPO/dists/stable/main/binary-arm64"

# Optional: flatten subdirectories only (if you keep this feature)
find "$REPO/$POOL" -mindepth 2 -type f -name '*.deb' -exec mv -t "$REPO/$POOL" {} +

# Generate the Packages and Packages.gz index from the .deb files in pool/
# IMPORTANT: run from $REPO and use a *relative* path ("pool")
(
  cd "$REPO"
  dpkg-scanpackages --multiversion "$POOL" > dists/stable/main/binary-arm64/Packages
  gzip -f9 dists/stable/main/binary-arm64/Packages
)

# Minimal Release file so APT can treat this like a repo
cat > "$REPO/dists/stable/Release" <<EOF
Origin: local
Label: local
Suite: stable
Codename: stable
Architectures: arm64
Components: main
Description: Local repo for FR v4 deps
EOF

echo "[*] Local repo is ready in $REPO"

