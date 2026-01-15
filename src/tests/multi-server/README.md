Multi server tests and environment configurations depend on the availability of the "freeradius-multi-server" test framework on your system.

freeradius-multi-server repo: https://github.com/InkbridgeNetworks/freeradius-multi-server

freeradius Docker image created from:
https://github.com/marc-casavant/freeradius-server/tree/dev-docker-build-from-src
```bash
freeradius-server % docker build --no-cache -t freeradius-dev-ubuntu24 -f scripts/docker/dev/build/ubuntu24/Dockerfile .
```

## Quick Setup
### Docker env, no tests running

Bring up the Docker env-loadgen-5hs test environment from the test framework (freeradius-multi-server) dir:

```bash
% cd $HOME/sandbox/freeradius-multi-server

freeradius-multi-server % make configure

freeradius-multi-server % source .venv/bin/activate

(.venv) freeradius-multi-server % TEST_LOGGER_CONFIG=linelog_file DATA_PATH=$HOME/sandbox/freeradius-server/src/tests/multi-server/environments/configs LISTENER_DIR=$HOME/freeradius-listener-logs docker compose -p custom_test-env-loadgen-5hs -f $HOME/sandbox/freeradius-server/src/tests/multi-server/environments/docker-compose/env-loadgen-5hs.yml up
```

### Run test using framework

Currently requires the changes from this branch of the test framework: https://github.com/InkbridgeNetworks/freeradius-multi-server/tree/custom-data-path-location

```bash
DATA_PATH=$HOME/sandbox/freeradius-server/src/tests/multi-server/environments/configs make test-framework-custom-config-path -- -x -vvvv --compose $HOME/sandbox/freeradius-server/src/tests/multi-server/environments/docker-compose/env-loadgen-5hs.yml --test $HOME/sandbox/freeradius-server/src/tests/multi-server/test-5hs-autoaccept.yml --use-files --listener-dir $HOME/freeradius-listener-logs
```
