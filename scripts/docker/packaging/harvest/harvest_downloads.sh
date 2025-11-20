#!/usr/bin/env bash
set -euo pipefail

OUT=/repo               # where we will write the local "repo" tree
PKGLIST=/work/packages.txt

mkdir -p "$OUT"
apt-get update

# Read package names from packages.txt:
#  - strip blank lines and comments
#  - pass them to apt-get install with --download-only (no install)
xargs -a "$PKGLIST" -- printf '%s\n' \
 | sed '/^\s*#/d;/^\s*$/d' \
 | tr '\n' ' ' \
 | xargs -r apt-get install -y --download-only --no-install-recommends

# All downloaded .debs are in /var/cache/apt/archives/
# Stage them in a temp dir before moving to repo/pool/
mkdir -p /tmp/pool
cp -v /var/cache/apt/archives/*.deb /tmp/pool/ || true

# Also include our custom libkqueue0 .deb if provided via /seed mount
if ls /seed/*.deb >/dev/null 2>&1; then
  cp -v /seed/*.deb /tmp/pool/
fi

# Deduplicate and move into the repo pool
mkdir -p "$OUT/pool"
( cd /tmp/pool && for f in *.deb; do
    [ -e "$f" ] || continue
    # move only if not already present
    [ -e "$OUT/pool/$f" ] || mv -v "$f" "$OUT/pool/"
  done )

echo "[*] Harvest complete: $(ls -1 "$OUT/pool" | wc -l) files in $OUT/pool"