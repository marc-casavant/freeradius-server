Development FreeRADIUS V4 build from source.  Additional scripts for libkqueue required since libkqueue > 2.6.3 libs are required for build.

Build command example:
```bash
cd <repo-root>
docker build --no-cache -t <your-image-name> -f scripts/docker/dev/build/ubuntu24/Dockerfile .
```

Docker compose entrypoint example required for EAP/PEAP certs:

```yaml
entrypoint:
  - bash
  - -lc
  - |
    set -euo pipefail

    apt-get update
    apt-get install -y snmp snmp-mibs-downloader less vim

    source /tmp/env-setup.sh
    export TEST_PROJECT_NAME=${COMPOSE_PROJECT_NAME}

    # Generate FreeRADIUS certs if missing (needed for eap/peap)
    if [ -e /etc/raddb/mods-enabled/eap ] && [ ! -f /etc/raddb/certs/rsa/server.pem ]; then
      (cd /etc/raddb/certs && make)
    fi
```
