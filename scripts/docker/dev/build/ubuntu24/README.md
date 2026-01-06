Development FreeRADIUS V4 build from source.  Additional scripts for libkqueue required since libkqueue > 2.6.3 libs are required for build.

Build example from repo root:
docker build --no-cache -t <your-image-name> -f scripts/docker/dev/build/ubuntu24/Dockerfile .
