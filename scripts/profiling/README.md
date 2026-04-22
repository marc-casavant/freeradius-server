# macOS Build And Callgrind Profiling

This guide is for building FreeRADIUS in developer mode with profiling symbols on macOS, then running a timed `valgrind --tool=callgrind` profile.

Run every command below from the repository root.

## 1. Prerequisites

Make sure these tools are available before you start:

- Xcode command line tools
- `valgrind`
- `qcachegrind`
- `gmake` or `make`
- `dsymutil`

Quick checks:

```bash
xcode-select -p
command -v valgrind
command -v qcachegrind
command -v gmake || command -v make
command -v dsymutil
```

If you need to install the macOS build dependencies used by this repository, review and run:

```bash
scripts/osx/install_deps.sh
```

## 2. Build And Profile Workflow

This is the recommended workflow when you want one build step and a separate timed profiling step.

### Step 1: Build Only In Developer Mode With Profiling Symbols

```bash
scripts/profiling/profile-callgrind.sh \
  --clean \
  --build-only \
  --cflags "-g3 -O1 -fno-omit-frame-pointer" \
  --ldflags "-fno-omit-frame-pointer" \
  --jobs "$(sysctl -n hw.ncpu)"
```

Equivalent shell commands without using `profile-callgrind.sh`:

```bash
xcrun gmake distclean || true
rm -rf build
xcrun ./configure \
  --enable-developer \
  --disable-verify-ptr \
  CFLAGS="-g3 -O1 -fno-omit-frame-pointer" \
  LDFLAGS="-fno-omit-frame-pointer"
xcrun gmake -j"$(sysctl -n hw.ncpu)"
```

### Step 2: Run A Timed Callgrind Profile With An Explicit Env File

```bash
scripts/profiling/profile-callgrind.sh \
  --profile-only \
  --env-file build/tests/multi-server/prof-accept/short_ci/freeradius/profiling-server/proto_load_config.env \
  --reset-radiusd-args \
  --radiusd-arg -f \
  --radiusd-arg -m \
  --radiusd-arg -l \
  --radiusd-arg stdout \
  --radiusd-conf-file raddb/radiusd.conf \
  --run-seconds 60
```

Equivalent shell commands without using `profile-callgrind.sh`:

```bash
mkdir -p build/callgrind
stamp="$(date +%Y%m%d-%H%M%S)"

set -a
source build/tests/multi-server/prof-accept/short_ci/freeradius/profiling-server/proto_load_config.env
set +a

dsymutil build/bin/local/radiusd || true
find build -type d -name '*.dSYM' -prune -o -type f \( -name '*.dylib' -o -name '*.so' \) -print0 | \
  while IFS= read -r -d '' module_file; do
    dsymutil "$module_file" || true
  done

valgrind \
  --tool=callgrind \
  --trace-children=yes \
  --separate-threads=yes \
  --dump-instr=yes \
  --collect-jumps=yes \
  --cache-sim=yes \
  --branch-sim=yes \
  --callgrind-out-file="$PWD/build/callgrind/callgrind.radiusd.${stamp}.%p" \
  ./scripts/bin/radiusd \
  -f \
  -m \
  -l stdout \
  -d "$PWD/raddb" \
  -n radiusd &

vg_pid=$!
sleep 60

pgrep -f "callgrind.radiusd.${stamp}.%p" | while IFS= read -r pid; do
  kill -INT "$pid" || true
done

wait "$vg_pid" || true
```

### Step 3: Open The Newest Callgrind Output

```bash
latest_file=$(find build/callgrind -maxdepth 1 -type f -name 'callgrind.radiusd.*' -size +0c -print0 | xargs -0 ls -t | head -n 1)
qcachegrind "$latest_file"
```

This step already is the direct shell command that `profile-callgrind.sh` would leave you to run manually.

### Optional: Use The Auto-Detected Default Env File

`--env-file` is optional. If you omit it, `profile-callgrind.sh` automatically sources `build/tests/multi-server/prof-accept/short_ci/freeradius/profiling-server/proto_load_config.env` when that file exists.

```bash
scripts/profiling/profile-callgrind.sh \
  --profile-only \
  --reset-radiusd-args \
  --radiusd-arg -f \
  --radiusd-arg -m \
  --radiusd-arg -l \
  --radiusd-arg stdout \
  --radiusd-conf-file raddb/radiusd.conf \
  --run-seconds 60
```

Equivalent shell commands without using `profile-callgrind.sh`:

```bash
mkdir -p build/callgrind
stamp="$(date +%Y%m%d-%H%M%S)"

set -a
source build/tests/multi-server/prof-accept/short_ci/freeradius/profiling-server/proto_load_config.env
set +a

dsymutil build/bin/local/radiusd || true
find build -type d -name '*.dSYM' -prune -o -type f \( -name '*.dylib' -o -name '*.so' \) -print0 | \
  while IFS= read -r -d '' module_file; do
    dsymutil "$module_file" || true
  done

valgrind \
  --tool=callgrind \
  --trace-children=yes \
  --separate-threads=yes \
  --dump-instr=yes \
  --collect-jumps=yes \
  --cache-sim=yes \
  --branch-sim=yes \
  --callgrind-out-file="$PWD/build/callgrind/callgrind.radiusd.${stamp}.%p" \
  ./scripts/bin/radiusd \
  -f \
  -m \
  -l stdout \
  -d "$PWD/raddb" \
  -n radiusd &

vg_pid=$!
sleep 60

pgrep -f "callgrind.radiusd.${stamp}.%p" | while IFS= read -r pid; do
  kill -INT "$pid" || true
done

wait "$vg_pid" || true
```

## 3. Exact Commands The Script Runs

The script wraps the same basic configure, build, and valgrind steps shown below.

### Configure

```bash
xcrun ./configure \
  --enable-developer \
  --disable-verify-ptr \
  CFLAGS="-g3 -O1 -fno-omit-frame-pointer" \
  LDFLAGS="-fno-omit-frame-pointer"
```

### Build

```bash
xcrun gmake -j"$(sysctl -n hw.ncpu)"
```

### Generate dSYM Information

By default the script runs `dsymutil` for the main `radiusd` binary and for built modules so that qcachegrind can resolve symbols more cleanly.

Main binary:

```bash
dsymutil build/bin/local/radiusd
```

If you want to skip dSYM generation, use `--no-dsym`. If you want the main binary dSYM but not module dSYMs, use `--no-dsym-modules`.

### Run Valgrind Callgrind

The script profiles the `scripts/bin/radiusd` wrapper by default, not `build/bin/local/radiusd` directly. The wrapper injects the repository-local dictionary and runtime library setup.

Equivalent valgrind launch for the profile-only example above:

```bash
mkdir -p build/callgrind
stamp="$(date +%Y%m%d-%H%M%S)"

set -a
source build/tests/multi-server/prof-accept/short_ci/freeradius/profiling-server/proto_load_config.env
set +a

valgrind \
  --tool=callgrind \
  --trace-children=yes \
  --separate-threads=yes \
  --dump-instr=yes \
  --collect-jumps=yes \
  --cache-sim=yes \
  --branch-sim=yes \
  --callgrind-out-file="$PWD/build/callgrind/callgrind.radiusd.${stamp}.%p" \
  ./scripts/bin/radiusd \
  -f \
  -m \
  -l stdout \
  -d "$PWD/raddb" \
  -n radiusd
```

## 4. What The Main Profiling Arguments Do

These are the arguments used in the recommended profile-only command.

- `--profile-only` skips configure and build and runs only the profiling phase.
- `--env-file <path>` sources an environment file before starting `radiusd`. This is used to export `TEST_LOADGEN_*` variables for the `listen load` configuration in `raddb/radiusd.conf`.
- `--reset-radiusd-args` clears the script's default `radiusd` arguments before later `--radiusd-arg` values are appended.
- `--radiusd-arg -f` keeps `radiusd` in the foreground so valgrind follows the live server process.
- `--radiusd-arg -m` preserves the runtime mode you were already using in wrapper-based runs.
- `--radiusd-arg -l` and `--radiusd-arg stdout` send server logs to standard output.
- `--radiusd-conf-file raddb/radiusd.conf` appends `-d <confdir> -n <name>` so `radiusd` uses the repository's `raddb/radiusd.conf` configuration.
- `--run-seconds 60` profiles for 60 seconds, then stops the valgrind processes for that run and writes the callgrind output files.

Useful related options:

- `--clean` removes existing build artifacts before configure and build.
- `--build-only` performs configure and build without launching valgrind.
- `--configure-only` performs only the configure step.
- `--no-dsym` skips all dSYM generation.
- `--no-dsym-modules` keeps dSYM generation for `radiusd` but skips module dSYMs.
- `--open` opens the selected callgrind file in `qcachegrind` at the end of the run.

## 5. Inspect Results

Confirm that a command history log was written:

```bash
ls -t build/callgrind/commands.radiusd.*.log | head -n 1
```

Inspect the newest log:

```bash
latest_log=$(ls -t build/callgrind/commands.radiusd.*.log | head -n 1)
sed -n '1,200p' "$latest_log"
```

Open the newest non-empty callgrind file:

```bash
latest_file=$(find build/callgrind -maxdepth 1 -type f -name 'callgrind.radiusd.*' -size +0c -print0 | xargs -0 ls -t | head -n 1)
qcachegrind "$latest_file"
```
