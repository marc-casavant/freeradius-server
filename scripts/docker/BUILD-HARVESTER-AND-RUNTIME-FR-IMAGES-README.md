From freeradius-server src directory.


Build harvester image:
```
export FR-EXTRA-PACKAGES-REPO="$HOME/sandbox/fr-packaging/repo"

docker buildx build \   
  --platform linux/arm64 \
  -t freeradius-deb-harvester:ubuntu24-arm64 \
  -f scripts/docker/build/ubuntu24/Dockerfile.ubuntu24.harvester \
  --build-context localrepo="$FR-EXTRA-PACKAGES-REPO" \
  --no-cache \                             
  --load \ 
  .
```

Get harvested debs and save to localhost directory:
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
Extra check to see if libkqueue debs are there:
```
ls fr-harvested-debs | grep -i kqueue
```

Build runtime image with harvested debs:
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

Run the image:
```
docker run --rm -p 1812:1812/udp -p 1813:1813/udp freeradius-server:ubuntu24-arm64
```