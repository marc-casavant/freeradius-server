
# FreeRADIUS Extra Packages Workflow for ARM64

## Directory structure layout

```
<packaging-dir>/
├─ repo/ # output: local apt repo (pool + index)
├─ libkqueue/
│  ├─ Dockerfile.arm64.libkqueue
│  ├─ patch-libkqueue-soname-0.cmake
│  └─ build_libkqueue_deb.sh
├─ harvest/
│  ├─ packages.txt # Currently only has libkqueue
│  ├─ Dockerfile.arm64.harvester
│  ├─ harvest_downloads.sh
│  └─ make_local_repo.sh
```

## 1) Build additional packages for FreeRADIUS
```
./build-fr-extra-packages.sh
```

## 2) Verify libkqueue debs harvested
Extra verification check to ensure they have the package has been properly created.  FreeRADIUS V4 is specific on the naming convension of the package name.
```
./verify-libkqueue.sh
```

## 3) Use packaged debs with NEW FreeRADIUS V4 Docker container workflow; build harvester and runtime images.
Refer to BUILD-HARVESTER-AND-RUNTIME-FR-IMAGES-README.md for instructions how to build FreeRADIUS harvester and runtime images based on these packages.
```
Resulting images (example):
- freeradius-deb-harvester:ubuntu24-arm64
- freeradius-server:ubuntu24-arm64

## 4) Once images are available, you can run the server
```
docker run --rm -p 1812:1812/udp -p 1813:1813/udp freeradius-server:ubuntu24-arm64
```
