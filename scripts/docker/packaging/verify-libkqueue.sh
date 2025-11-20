#!/usr/bin/env bash
set -euo pipefail


# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL_DIR="$SCRIPT_DIR/repo/pool"

echo "[verify-libkqueue] Verifying libkqueue debs in $POOL_DIR"

if [ ! -d "$POOL_DIR" ]; then
  echo "ERROR: $POOL_DIR does not exist. Did you run run-fr-packaging-workflow.sh first?" >&2
  exit 1
fi

run_local_check() {
  local runtime_deb dev_deb old_runtime

  runtime_deb=$(ls "$POOL_DIR"/libkqueue0_*.deb 2>/dev/null || true)
  dev_deb=$(ls "$POOL_DIR"/libkqueue-dev_*.deb 2>/dev/null || true)

  if [ -z "$runtime_deb" ]; then
    echo "ERROR: No libkqueue0_*.deb found in $POOL_DIR" >&2
    exit 1
  fi

  if [ -z "$dev_deb" ]; then
    echo "ERROR: No libkqueue-dev_*.deb found in $POOL_DIR" >&2
    exit 1
  fi

  # Warn if old libkqueue_* runtime debs linger
  old_runtime=$(ls "$POOL_DIR"/libkqueue_[0-9]*.deb 2>/dev/null || true)
  if [ -n "$old_runtime" ]; then
    echo "WARNING: Found legacy libkqueue_* runtime deb(s) in $POOL_DIR:"
    echo "$old_runtime"
    echo "         These are from the old scheme; you can delete them."
  fi

  echo "[verify-libkqueue] Using runtime deb: $(basename "$runtime_deb")"
  echo "[verify-libkqueue] Using dev deb:     $(basename "$dev_deb")"

  local runtime_pkg runtime_prov dev_pkg dev_deps

  runtime_pkg=$(dpkg-deb --field "$runtime_deb" Package)
  runtime_prov=$(dpkg-deb --field "$runtime_deb" Provides 2>/dev/null || true)
  dev_pkg=$(dpkg-deb --field "$dev_deb" Package)
  dev_deps=$(dpkg-deb --field "$dev_deb" Depends 2>/dev/null || true)

  echo "[verify-libkqueue] Runtime Package:  $runtime_pkg"
  echo "[verify-libkqueue] Runtime Provides: ${runtime_prov:-<none>}"
  echo "[verify-libkqueue] Dev Package:      $dev_pkg"
  echo "[verify-libkqueue] Dev Depends:      ${dev_deps:-<none>}"
  echo

  if [ "$runtime_pkg" != "libkqueue0" ]; then
    echo "ERROR: Runtime Package is '$runtime_pkg', expected 'libkqueue0'" >&2
    exit 1
  fi

  if ! echo "$runtime_prov" | grep -q "libkqueue"; then
    echo "ERROR: Runtime package does not Provide: libkqueue" >&2
    exit 1
  fi

  if [ "$dev_pkg" != "libkqueue-dev" ]; then
    echo "ERROR: Dev Package is '$dev_pkg', expected 'libkqueue-dev'" >&2
    exit 1
  fi

  if ! echo "$dev_deps" | grep -q "libkqueue0"; then
    echo "ERROR: Dev package Depends does not reference libkqueue0" >&2
    exit 1
  fi

  if echo "$dev_deps" | grep -q "libkqueue0 (>= 2.6.1)"; then
    echo "[verify-libkqueue] Dev Depends includes 'libkqueue0 (>= 2.6.1)'"
  else
    echo "WARNING: Dev package Depends on libkqueue0 but not with '(>= 2.6.1)'."
    echo "         This is usually OK, but differs from the expected constraint."
  fi

  echo
  echo "[verify-libkqueue] ✅ libkqueue0 + libkqueue-dev look good."
}

run_docker_check() {
  echo "[verify-libkqueue] 'dpkg-deb' not found on host; verifying inside Ubuntu container..."

  docker run --rm \
    -v "$PWD/repo:/repo:ro" \
    ubuntu:24.04 \
    bash -lc '
      set -euo pipefail
      apt-get update -qq
      apt-get install -y -qq dpkg-dev >/dev/null

      POOL_DIR=/repo/pool
      runtime_deb=$(ls "$POOL_DIR"/libkqueue0_*.deb 2>/dev/null || true)
      dev_deb=$(ls "$POOL_DIR"/libkqueue-dev_*.deb 2>/dev/null || true)

      if [ -z "$runtime_deb" ]; then
        echo "ERROR: No libkqueue0_*.deb found in $POOL_DIR" >&2
        exit 1
      fi

      if [ -z "$dev_deb" ]; then
        echo "ERROR: No libkqueue-dev_*.deb found in $POOL_DIR" >&2
        exit 1
      fi

      echo "[verify-libkqueue] Using runtime deb: $(basename "$runtime_deb")"
      echo "[verify-libkqueue] Using dev deb:     $(basename "$dev_deb")"

      runtime_pkg=$(dpkg-deb --field "$runtime_deb" Package)
      runtime_prov=$(dpkg-deb --field "$runtime_deb" Provides 2>/dev/null || true)
      dev_pkg=$(dpkg-deb --field "$dev_deb" Package)
      dev_deps=$(dpkg-deb --field "$dev_deb" Depends 2>/dev/null || true)

      echo "[verify-libkqueue] Runtime Package:  $runtime_pkg"
      echo "[verify-libkqueue] Runtime Provides: ${runtime_prov:-<none>}"
      echo "[verify-libkqueue] Dev Package:      $dev_pkg"
      echo "[verify-libkqueue] Dev Depends:      ${dev_deps:-<none>}"
      echo

      if [ "$runtime_pkg" != "libkqueue0" ]; then
        echo "ERROR: Runtime Package is '\''$runtime_pkg'\'', expected '\''libkqueue0'\''" >&2
        exit 1
      fi

      if ! echo "$runtime_prov" | grep -q "libkqueue"; then
        echo "ERROR: Runtime package does not Provide: libkqueue" >&2
        exit 1
      fi

      if [ "$dev_pkg" != "libkqueue-dev" ]; then
        echo "ERROR: Dev Package is '\''$dev_pkg'\'', expected '\''libkqueue-dev'\''" >&2
        exit 1
      fi

      if ! echo "$dev_deps" | grep -q "libkqueue0"; then
        echo "ERROR: Dev package Depends does not reference libkqueue0" >&2
        exit 1
      fi

      if echo "$dev_deps" | grep -q "libkqueue0 (>= 2.6.1)"; then
        echo "[verify-libkqueue] Dev Depends includes '\''libkqueue0 (>= 2.6.1)'\''"
      else
        echo "WARNING: Dev package Depends on libkqueue0 but not with '\''(>= 2.6.1)'\''."
      fi

      echo
      echo "[verify-libkqueue] ✅ libkqueue0 + libkqueue-dev look good (checked in container)."
    '
}

if command -v dpkg-deb >/dev/null 2>&1; then
  run_local_check
else
  run_docker_check
fi
