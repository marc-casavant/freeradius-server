#!/usr/bin/env bash
set -euo pipefail

#
# Build libkqueue and produce:
#   - libkqueue0_<version>_arm64.deb  (runtime)
#   - libkqueue-dev_<version>_arm64.deb (dev, Depends: ... libkqueue0 ...)
#

# Upstream libkqueue tag
: "${LIBKQUEUE_TAG:=v2.6.3}"

# Working dirs (inside container)
work=/work
src=$work/src
build=$work/build

# Output repo root (shared with host)
: "${OUT_REPO:=/repo}"
out="${OUT_REPO}"

mkdir -p "$src" "$build" "$out/pool"

echo "[*] Clone libkqueue ${LIBKQUEUE_TAG}"
git clone --branch "$LIBKQUEUE_TAG" --depth 1 \
  https://github.com/mheily/libkqueue.git \
  "$src/libkqueue"

# Append SONAME override so libkqueue.so.0 is built
cat "$work/patch-libkqueue-soname-0.cmake" >> "$src/libkqueue/CMakeLists.txt"

echo "[*] Configure CMake for a Debian package via CPack"
cmake -S "$src/libkqueue" -B "$build/libkqueue" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCPACK_GENERATOR=DEB \
  -DCPACK_DEBIAN_PACKAGE_SHLIBDEPS=ON

echo "[*] Build the library"
cmake --build "$build/libkqueue" -j"$(nproc)"

echo "[*] Produce .debs using CPack"
(
  cd "$build/libkqueue"
  cpack -G DEB
)

echo "[*] Post-process .debs to:
      - rename runtime package to libkqueue0 + Provides: libkqueue
      - make dev package depend on libkqueue0"

for deb in "$build"/libkqueue/*.deb; do
  pkgname=$(dpkg-deb --field "$deb" Package)
  echo "    - Found package $pkgname in $(basename "$deb")"

  if [ "$pkgname" = "libkqueue" ]; then
    #
    # Runtime package → libkqueue0 + Provides: libkqueue
    #
    echo "      -> Rewriting runtime package to libkqueue0 + Provides: libkqueue"
    tmpdir=$(mktemp -d)
    dpkg-deb -R "$deb" "$tmpdir"
    control="$tmpdir/DEBIAN/control"

    # 1) Package: libkqueue → Package: libkqueue0
    sed -i 's/^Package: libkqueue$/Package: libkqueue0/' "$control"

    # 2) Ensure Provides: libkqueue exists
    if grep -q '^Provides:' "$control"; then
      if ! grep -q '^Provides:.*libkqueue' "$control"; then
        sed -i 's/^Provides: \(.*\)$/Provides: \1, libkqueue/' "$control"
      fi
    else
      sed -i '/^Package: libkqueue0$/a Provides: libkqueue' "$control"
    fi

    # 3) Fix DEBIAN/shlibs so dpkg-shlibdeps chooses libkqueue0, not libkqueue
    shlibs="$tmpdir/DEBIAN/shlibs"
    if [ -f "$shlibs" ]; then
      echo "      -> Patching shlibs to map library to libkqueue0"
      # "libkqueue 0 libkqueue (>= 2.6.1)" → "libkqueue 0 libkqueue0 (>= 2.6.1)"
      sed -i 's/\(libkqueue[[:space:]]\+[0-9.]*[[:space:]]\+\)libkqueue\(\b\)/\1libkqueue0\2/' "$shlibs"
    fi

    # Rebuild the .deb with new name libkqueue0_*.deb
    newdeb="${deb/libkqueue_/libkqueue0_}"
    dpkg-deb -b "$tmpdir" "$newdeb"
    rm -rf "$tmpdir"

    rm -f "$deb"
    echo "      -> Repacked runtime as $(basename "$newdeb")"

  elif [ "$pkgname" = "libkqueue-dev" ]; then
    #
    # Dev package → Depends on libkqueue0 instead of libkqueue
    #
    echo "      -> Fixing dev package Depends to reference libkqueue0"
    tmpdir=$(mktemp -d)
    dpkg-deb -R "$deb" "$tmpdir"
    control="$tmpdir/DEBIAN/control"

    if grep -q '^Depends:.*libkqueue' "$control"; then
      # Replace libkqueue with libkqueue0 only in Depends: line
      sed -i 's/\(^Depends:.*\)libkqueue/\1libkqueue0/' "$control"
    else
      # No explicit libkqueue dep – ensure libkqueue0 is added
      if grep -q '^Depends:' "$control"; then
        sed -i 's/^Depends: \(.*\)$/Depends: \1, libkqueue0/' "$control"
      else
        echo "Depends: libkqueue0" >> "$control"
      fi
    fi

    # Optionally enforce lower bound (>= 2.6.1), but not strictly required:
    # if ! grep -q "libkqueue0 (>= 2.6.1)" "$control"; then
    #   sed -i 's/libkqueue0/libkqueue0 (>= 2.6.1)/' "$control"
    # fi

    newdeb="${deb%.deb}.fixed.deb"
    dpkg-deb -b "$tmpdir" "$newdeb"
    rm -rf "$tmpdir"

    mv "$newdeb" "$deb"
    echo "      -> Repacked dev as $(basename "$deb")"
  fi
done

echo "[*] Copy resulting .debs into $out/pool"
mv -v "$build"/libkqueue/*.deb "$out/pool/"

echo "[*] Done. libkqueue-related .debs in $out/pool:"
ls -l "$out/pool"