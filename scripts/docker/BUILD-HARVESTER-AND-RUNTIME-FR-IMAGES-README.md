# Ubuntu24 ARM64 Harvester and Runtime Builds

## Dependencies

- libkqueue >= 2.6.3 packages available in `<freeradius-server-src>/scripts/docker/packaging/repo`

  - If the libkqueue*.deb files have not been generated, run the `build-fr-extra-packages.sh` script located in `<freeradius-server-src>/scripts/docker/packaging`.

## Automated build

### Using defaults:

`<freeradius-server-localrepo-src>/scripts/docker/build-harvester-and-runtime-fr-images.sh`

### Optional deb harvester and runtime image names:

`<freeradius-server-localrepo-src>/scripts/docker/build-harvester-and-runtime-fr-images.sh [extra-packages-repo] [harvester-image-name] [runtime-image-name]`

- extra-packages-repo: Absolute path to fr-extra-packages repo (auto-detects if omitted)
- harvester-image:     Optional custom harvester image name
- runtime-image:       Optional custom runtime image name

Image name examples:
- freeradius-deb-harvester:ubuntu24-arm64

- freeradius-server:ubuntu24-arm64

## Manual build steps

NOTE: Build from `<freeradius-server-src>`

### Build FR harvester image:
```
docker buildx build \
  --platform linux/arm64 \
  -t freeradius-deb-harvester:ubuntu24-arm64 \
  -f scripts/docker/build/ubuntu24/Dockerfile.ubuntu24.harvester \
  --build-context localrepo="scripts/docker/packaging/repo" \
  --no-cache \
  --load \
  .
```

### Get harvested debs and save to localhost directory:
```
rm -rf fr-harvested-debs
mkdir -p fr-harvested-debs

docker run --rm \
  -v "$PWD/fr-harvested-debs:/out" \
  freeradius-deb-harvester:ubuntu24-arm64 \
  bash -c '
    set -e
    cp /usr/local/src/repositories/*.deb /out/
    find /opt/localrepo -type f -name "*.deb" -exec cp {} /out/ \;
  '
```
### Extra check to see if libkqueue debs are there:
```
ls fr-harvested-debs | grep -i kqueue
```

### Build runtime image with harvested debs:
```
docker buildx build \
  --platform linux/arm64 \
  -t freeradius-server:ubuntu24-arm64 \
  -f scripts/docker/build/ubuntu24/Dockerfile.ubuntu24.runtime \
  --build-context localrepo="./fr-harvested-debs" \
  --no-cache \
  --load \
  .
```

## Run the FreeRADIUS server
```
docker run --rm -p 1812:1812/udp -p 1813:1813/udp freeradius-server:ubuntu24-arm64
```
