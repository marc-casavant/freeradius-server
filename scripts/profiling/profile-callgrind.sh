#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]; then
  printf 'ERROR: Valgrind/callgrind does not support macOS on Apple Silicon (arm64) without having highly possible OS crashes.\n' >&2
  printf 'Use a Linux aarch64 container or VM to run this script.\n' >&2
  exit 1
fi

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

MAKE_CMD=()
if command -v xcrun >/dev/null 2>&1 && xcrun --find gmake >/dev/null 2>&1; then
  MAKE_CMD=(xcrun gmake)
elif command -v gmake >/dev/null 2>&1; then
  MAKE_CMD=(gmake)
else
  MAKE_CMD=(make)
fi

DO_CONFIGURE=1
DO_BUILD=1
DO_PROFILE=1
CLEAN_FIRST=0
OPEN_QCACHEGRIND=0
DRY_RUN=0
GENERATE_DSYM=1
GENERATE_MODULE_DSYM=1
RUN_SECONDS=0
STARTUP_DELAY=2
WORKLOAD_RADCLIENT_BURST=0
SKIP_STARTUP=0

RADCLIENT_BIN="$ROOT_DIR/scripts/bin/radclient"
RADCLIENT_COUNT=1000
RADCLIENT_SERVER="localhost"
RADCLIENT_SECRET="testing123"
RADCLIENT_NAS_PORT="0"
RADCLIENT_USER_PREFIX="prof"
RADCLIENT_PASSWORD="hello"
RADCLIENT_PARALLEL="50"
RADCLIENT_RATE="0"

CONFIGURE_ARGS=("--enable-developer" "--disable-verify-ptr")
EXTRA_CONFIGURE_ARGS=()

BUILD_CMD=("${MAKE_CMD[@]}" "-j${JOBS}")

CFLAGS_VALUE="-g3 -O1 -fno-omit-frame-pointer"
LDFLAGS_VALUE="-fno-omit-frame-pointer"

RADIUSD_BIN="$ROOT_DIR/scripts/bin/radiusd"
RADIUSD_ARGS=("-f" "-m")
RADIUSD_CONF_FILE=""
ENV_FILES=()
DEFAULT_ENV_FILE="$ROOT_DIR/build/tests/multi-server/prof-accept/short_ci/freeradius/profiling-server/proto_load_config.env"

VALGRIND_ARGS=(
  "--tool=callgrind"
  "--trace-children=yes"
  "--separate-threads=yes"
  "--dump-instr=yes"
  "--collect-jumps=yes"
  "--cache-sim=yes"
  "--branch-sim=yes"
)

OUT_DIR="$ROOT_DIR/build/callgrind"
OUT_PREFIX="radiusd"
WORKLOAD_CMD=""
COMMAND_HISTORY=()
COMMAND_LOG_FILE=""
COMMAND_LOG_WRITTEN=0

record_cmd() {
  local rendered
  printf -v rendered '%q ' "$@"
  COMMAND_HISTORY+=("${rendered% }")
}

record_cmd_str() {
  COMMAND_HISTORY+=("$1")
}

write_command_history_log() {
  local exit_code="$1"
  local hist_stamp
  local i

  if [[ "$COMMAND_LOG_WRITTEN" -eq 1 ]]; then
    return 0
  fi
  COMMAND_LOG_WRITTEN=1

  mkdir -p "$OUT_DIR" >/dev/null 2>&1 || true
  hist_stamp="$(date +%Y%m%d-%H%M%S)"
  COMMAND_LOG_FILE="$OUT_DIR/commands.${OUT_PREFIX}.${hist_stamp}.log"

  {
    printf '# profile-callgrind command history\n'
    printf 'exit_code: %s\n' "$exit_code"
    printf 'cwd: %s\n' "$ROOT_DIR"
    printf 'dry_run: %s\n' "$DRY_RUN"
    printf 'generated_at: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Commands:\n'
    i=1
    if [[ ${#COMMAND_HISTORY[@]} -gt 0 ]]; then
      for cmd in "${COMMAND_HISTORY[@]}"; do
        printf '%03d %s\n' "$i" "$cmd"
        i=$((i + 1))
      done
    fi
  } > "$COMMAND_LOG_FILE"

  log "Command history log: $COMMAND_LOG_FILE"
}

on_exit() {
  local exit_code=$?

  if declare -F cleanup >/dev/null 2>&1; then
    cleanup || true
  fi

  write_command_history_log "$exit_code"

  trap - EXIT
  exit "$exit_code"
}

trap on_exit EXIT

usage() {
  cat <<'EOF'
Usage: scripts/profiling/profile-callgrind.sh [options]

Build and profile FreeRADIUS radiusd with valgrind/callgrind on macOS.

Common examples:
  scripts/profiling/profile-callgrind.sh
  scripts/profiling/profile-callgrind.sh --clean --open
  scripts/profiling/profile-callgrind.sh --skip-configure --skip-build --run-seconds 20
  scripts/profiling/profile-callgrind.sh --profile-only --radclient-count 5000 --run-seconds 30
  scripts/profiling/profile-callgrind.sh --configure-arg --with-experimental-modules
  scripts/profiling/profile-callgrind.sh --workload-cmd "./build/bin/local/radclient -x 127.0.0.1 auth testing123"

Options:
  --clean                      Remove build artifacts before configure/build.
  --configure-only             Run configure only.
  --build-only                 Run configure + build only (skip profiling).
  --profile-only               Run profiling only (skip configure/build).
  --skip-configure             Skip configure step.
  --skip-build                 Skip build step.
  --run-seconds N              Auto-stop profiler after N seconds.
  --skip-startup               Start callgrind collection only when workload begins.
  --startup-delay N            Seconds to wait before running workload (default: 2).
  --workload-cmd CMD           Run a command while radiusd is under callgrind.
  --radclient-burst            Enable radclient burst workload (default: disabled).
  --no-radclient-burst         Disable built-in radclient burst workload.
  --radclient-bin PATH         Path to radclient binary (default: scripts/bin/radclient).
  --radclient-count N          Number of Access-Requests to send (default: 1000).
  --radclient-server HOST[:PORT]
                                RADIUS server for radclient (default: localhost).
  --radclient-secret SECRET    Shared secret for radclient (default: testing123).
  --radclient-nas-port NUM     NAS-Port value in each request (default: 0).
  --radclient-user-prefix STR  User-Name prefix for generated requests (default: prof).
  --radclient-password PASS    User-Password in generated requests (default: hello).
  --radclient-parallel N       Concurrent packets from request file (default: 50).
  --radclient-rate N           Max requests/s via -n (0 means unset, default: 0).
  --open                       Open resulting callgrind file in qcachegrind.
  --dry-run                    Print commands without executing them.

  --configure-arg ARG          Append one extra configure argument (repeatable).
  --cflags FLAGS               Override CFLAGS passed to configure.
  --ldflags FLAGS              Override LDFLAGS passed to configure.

  --env-file FILE              Source FILE into the environment before starting radiusd
                                (repeatable). If omitted, the script will auto-source
                                build/tests/.../profiling-server/proto_load_config.env
                                when that file exists.
  --radiusd-bin PATH           Path to radiusd launcher/binary.
                                Default: scripts/bin/radiusd wrapper.
  --radiusd-conf-file PATH     Path to a specific radiusd .conf file.
                                This automatically sets -d and -n for radiusd.
  --radiusd-arg ARG            Append one radiusd arg (repeatable).
  --reset-radiusd-args         Clear default radiusd args before adding new ones.

  --valgrind-arg ARG           Append one valgrind argument (repeatable).
  --reset-valgrind-args        Clear default valgrind args before adding new ones.

  --out-dir PATH               Output directory for callgrind files.
  --out-prefix NAME            Prefix for callgrind output files.

  --no-dsym                    Skip dsymutil for radiusd and modules.
  --dsym-modules               Run dsymutil for built module shared libraries (default).
  --no-dsym-modules            Skip dsymutil for built module shared libraries.

  --jobs N                     Parallel build jobs.
  --help                       Show this help.

Examples:

  Run without rebuild (profile only):
    scripts/profiling/profile-callgrind.sh \
      --profile-only \
      --no-dsym \
      --radiusd-conf-file raddb/radiusd.conf \
      --run-seconds 60

    # Default wrapper launch is equivalent to:
    #   scripts/bin/radiusd -f -m -d <repo>/raddb -D <repo>/share/dictionary

    # Open the newest non-empty callgrind file
    latest_file=$(find build/callgrind -maxdepth 1 -type f -name 'callgrind.radiusd.*' -size +0c -print0 | xargs -0 ls -t | head -n 1)
    qcachegrind "$latest_file"

  Run with clean reconfigure + rebuild:
    scripts/profiling/profile-callgrind.sh \
      --clean \
      --configure-arg --with-experimental-modules \
      --cflags "-g3 -O1 -fno-omit-frame-pointer" \
      --ldflags "-fno-omit-frame-pointer" \
      --jobs 16

  Rebuild customization notes:
    --configure-arg <arg>     Add extra configure flags (repeatable)
    --cflags "<flags>"        Override CFLAGS for configure
    --ldflags "<flags>"       Override LDFLAGS for configure
    --jobs <N>                Set parallel build jobs

  If you want reconfigure/rebuild, do not pass:
    --profile-only
    --skip-configure
    --skip-build

EOF
}

log() {
  printf '[profile-callgrind] %s\n' "$*"
}

run_cmd() {
  record_cmd "$@"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --clean)
      CLEAN_FIRST=1
      ;;
    --configure-only)
      DO_CONFIGURE=1
      DO_BUILD=0
      DO_PROFILE=0
      ;;
    --build-only)
      DO_CONFIGURE=1
      DO_BUILD=1
      DO_PROFILE=0
      ;;
    --profile-only)
      DO_CONFIGURE=0
      DO_BUILD=0
      DO_PROFILE=1
      ;;
    --skip-configure)
      DO_CONFIGURE=0
      ;;
    --skip-build)
      DO_BUILD=0
      ;;
    --run-seconds)
      shift
      RUN_SECONDS="${1:?missing value for --run-seconds}"
      ;;
    --skip-startup)
      SKIP_STARTUP=1
      ;;
    --startup-delay)
      shift
      STARTUP_DELAY="${1:?missing value for --startup-delay}"
      ;;
    --workload-cmd)
      shift
      WORKLOAD_CMD="${1:?missing value for --workload-cmd}"
      ;;
    --radclient-burst)
      WORKLOAD_RADCLIENT_BURST=1
      ;;
    --no-radclient-burst)
      WORKLOAD_RADCLIENT_BURST=0
      ;;
    --radclient-bin)
      shift
      RADCLIENT_BIN="${1:?missing value for --radclient-bin}"
      ;;
    --radclient-count)
      shift
      RADCLIENT_COUNT="${1:?missing value for --radclient-count}"
      ;;
    --radclient-server)
      shift
      RADCLIENT_SERVER="${1:?missing value for --radclient-server}"
      ;;
    --radclient-secret)
      shift
      RADCLIENT_SECRET="${1:?missing value for --radclient-secret}"
      ;;
    --radclient-nas-port)
      shift
      RADCLIENT_NAS_PORT="${1:?missing value for --radclient-nas-port}"
      ;;
    --radclient-user-prefix)
      shift
      RADCLIENT_USER_PREFIX="${1:?missing value for --radclient-user-prefix}"
      ;;
    --radclient-password)
      shift
      RADCLIENT_PASSWORD="${1:?missing value for --radclient-password}"
      ;;
    --radclient-parallel)
      shift
      RADCLIENT_PARALLEL="${1:?missing value for --radclient-parallel}"
      ;;
    --radclient-rate)
      shift
      RADCLIENT_RATE="${1:?missing value for --radclient-rate}"
      ;;
    --open)
      OPEN_QCACHEGRIND=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;

    --configure-arg)
      shift
      EXTRA_CONFIGURE_ARGS+=("${1:?missing value for --configure-arg}")
      ;;
    --cflags)
      shift
      CFLAGS_VALUE="${1:?missing value for --cflags}"
      ;;
    --ldflags)
      shift
      LDFLAGS_VALUE="${1:?missing value for --ldflags}"
      ;;

    --env-file)
      shift
      ENV_FILES+=("${1:?missing value for --env-file}")
      ;;

    --radiusd-bin)
      shift
      RADIUSD_BIN="${1:?missing value for --radiusd-bin}"
      ;;
    --radiusd-conf-file)
      shift
      RADIUSD_CONF_FILE="${1:?missing value for --radiusd-conf-file}"
      ;;
    --radiusd-arg)
      shift
      RADIUSD_ARGS+=("${1:?missing value for --radiusd-arg}")
      ;;
    --reset-radiusd-args)
      RADIUSD_ARGS=()
      ;;

    --valgrind-arg)
      shift
      VALGRIND_ARGS+=("${1:?missing value for --valgrind-arg}")
      ;;
    --reset-valgrind-args)
      VALGRIND_ARGS=()
      ;;

    --out-dir)
      shift
      OUT_DIR="${1:?missing value for --out-dir}"
      ;;
    --out-prefix)
      shift
      OUT_PREFIX="${1:?missing value for --out-prefix}"
      ;;

    --no-dsym)
      GENERATE_DSYM=0
      GENERATE_MODULE_DSYM=0
      ;;
    --dsym-modules)
      GENERATE_MODULE_DSYM=1
      ;;
    --no-dsym-modules)
      GENERATE_MODULE_DSYM=0
      ;;

    --jobs)
      shift
      JOBS="${1:?missing value for --jobs}"
      BUILD_CMD=("${MAKE_CMD[@]}" "-j${JOBS}")
      ;;

    *)
      printf 'ERROR: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$RUN_SECONDS" != "0" ]] && ! [[ "$RUN_SECONDS" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: --run-seconds expects an integer >= 0\n' >&2
  exit 2
fi

if ! [[ "$STARTUP_DELAY" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: --startup-delay expects an integer >= 0\n' >&2
  exit 2
fi

if [[ -n "$WORKLOAD_CMD" ]]; then
  WORKLOAD_RADCLIENT_BURST=0
fi

if ! [[ "$RADCLIENT_COUNT" =~ ^[0-9]+$ ]] || [[ "$RADCLIENT_COUNT" -lt 1 ]]; then
  printf 'ERROR: --radclient-count expects an integer >= 1\n' >&2
  exit 2
fi

if ! [[ "$RADCLIENT_PARALLEL" =~ ^[0-9]+$ ]] || [[ "$RADCLIENT_PARALLEL" -lt 1 ]]; then
  printf 'ERROR: --radclient-parallel expects an integer >= 1\n' >&2
  exit 2
fi

if ! [[ "$RADCLIENT_RATE" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: --radclient-rate expects an integer >= 0\n' >&2
  exit 2
fi

if [[ -n "$RADIUSD_CONF_FILE" ]]; then
  radiusd_conf_path="$RADIUSD_CONF_FILE"

  case "$radiusd_conf_path" in
    /*) ;;
    *)
      radiusd_conf_path="$ROOT_DIR/$radiusd_conf_path"
      ;;
  esac

  if [[ ! -f "$radiusd_conf_path" ]]; then
    printf 'ERROR: --radiusd-conf-file not found: %s\n' "$radiusd_conf_path" >&2
    exit 2
  fi

  radiusd_conf_base="$(basename "$radiusd_conf_path")"
  case "$radiusd_conf_base" in
    *.conf) ;;
    *)
      printf 'ERROR: --radiusd-conf-file must end with .conf: %s\n' "$radiusd_conf_path" >&2
      exit 2
      ;;
  esac

  radiusd_conf_dir="$(cd "$(dirname "$radiusd_conf_path")" && pwd)"
  radiusd_conf_name="${radiusd_conf_base%.conf}"

  RADIUSD_ARGS+=("-d" "$radiusd_conf_dir" "-n" "$radiusd_conf_name")
fi

if [[ "${#ENV_FILES[@]}" -eq 0 ]] && [[ -f "$DEFAULT_ENV_FILE" ]]; then
  ENV_FILES+=("$DEFAULT_ENV_FILE")
  log "Auto-sourcing default env file: $DEFAULT_ENV_FILE"
fi

for _env_file in "${ENV_FILES[@]+"${ENV_FILES[@]}"}"; do
  case "$_env_file" in
    /*) ;;
    *) _env_file="$ROOT_DIR/$_env_file" ;;
  esac
  if [[ ! -f "$_env_file" ]]; then
    printf 'ERROR: --env-file not found: %s\n' "$_env_file" >&2
    exit 2
  fi
  # shellcheck source=/dev/null
  set -a
  source "$_env_file"
  set +a
done

if [[ "$CLEAN_FIRST" -eq 1 ]]; then
  log "Cleaning build artifacts"
  run_cmd "${MAKE_CMD[@]}" distclean || true
  run_cmd rm -rf "$ROOT_DIR/build"
fi

if [[ "$DO_CONFIGURE" -eq 1 ]]; then
  require_cmd xcrun
  log "Running configure"
  configure_cmd=(xcrun ./configure "${CONFIGURE_ARGS[@]}")
  if [[ ${#EXTRA_CONFIGURE_ARGS[@]} -gt 0 ]]; then
    configure_cmd+=("${EXTRA_CONFIGURE_ARGS[@]}")
  fi
  configure_cmd+=("CFLAGS=$CFLAGS_VALUE" "LDFLAGS=$LDFLAGS_VALUE")
  run_cmd "${configure_cmd[@]}"
fi

if [[ "$DO_BUILD" -eq 1 ]]; then
  if [[ "${MAKE_CMD[0]}" == "xcrun" ]]; then
    require_cmd xcrun
  else
    require_cmd "${MAKE_CMD[0]}"
  fi
  log "Building with ${JOBS} jobs"
  run_cmd "${BUILD_CMD[@]}"
fi

if [[ "$DO_PROFILE" -eq 0 ]]; then
  log "Done (configure/build path only)"
  exit 0
fi

require_cmd valgrind
require_cmd callgrind_annotate
if [[ "$SKIP_STARTUP" -eq 1 ]]; then
  require_cmd callgrind_control
fi

if [[ ! -x "$RADIUSD_BIN" ]]; then
  printf 'ERROR: radiusd binary not found or not executable: %s\n' "$RADIUSD_BIN" >&2
  exit 1
fi

RADIUSD_DSYM_TARGET="$RADIUSD_BIN"
if command -v file >/dev/null 2>&1; then
  if ! file -b "$RADIUSD_DSYM_TARGET" 2>/dev/null | grep -q 'Mach-O'; then
    if [[ -x "$ROOT_DIR/build/bin/local/radiusd" ]] && file -b "$ROOT_DIR/build/bin/local/radiusd" 2>/dev/null | grep -q 'Mach-O'; then
      RADIUSD_DSYM_TARGET="$ROOT_DIR/build/bin/local/radiusd"
    fi
  fi
fi

if [[ "$GENERATE_DSYM" -eq 1 ]] && command -v dsymutil >/dev/null 2>&1; then
  if command -v file >/dev/null 2>&1 && ! file -b "$RADIUSD_DSYM_TARGET" 2>/dev/null | grep -q 'Mach-O'; then
    log "Skipping radiusd dSYM generation (not a Mach-O binary): $RADIUSD_DSYM_TARGET"
  else
    log "Generating dSYM for radiusd"
    run_cmd dsymutil "$RADIUSD_DSYM_TARGET" || true
  fi
fi

if [[ "$GENERATE_MODULE_DSYM" -eq 1 ]] && command -v dsymutil >/dev/null 2>&1; then
  log "Generating dSYM for modules (this can take a while)"
  while IFS= read -r -d '' module_file; do
    run_cmd dsymutil "$module_file" || true
  done < <(find "$ROOT_DIR/build" -type d -name '*.dSYM' -prune -o -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
fi

run_cmd mkdir -p "$OUT_DIR"

stamp="$(date +%Y%m%d-%H%M%S)"
out_pattern="$OUT_DIR/callgrind.${OUT_PREFIX}.${stamp}.%p"

log "Starting radiusd under callgrind"
find_profile_pids() {
  {
    if [[ -n "${vg_pid:-}" ]] && kill -0 "$vg_pid" >/dev/null 2>&1; then
      printf '%s\n' "$vg_pid"
    fi

    if command -v pgrep >/dev/null 2>&1 && [[ -n "${stamp:-}" ]]; then
      pgrep -f -- "callgrind.${OUT_PREFIX}.${stamp}.%p" || true
    fi
  } | awk '/^[0-9]+$/ { print }' | sort -u
}

signal_profile_pids() {
  local signal_name="$1"
  local pid

  while IFS= read -r pid; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "-$signal_name" "$pid" || true
    fi
  done < <(find_profile_pids)
}

wait_for_profile_exit() {
  local deadline pid any_alive

  deadline=$((SECONDS + 3))
  while (( SECONDS < deadline )); do
    any_alive=0
    while IFS= read -r pid; do
      if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
        any_alive=1
        break
      fi
    done < <(find_profile_pids)

    if [[ "$any_alive" -eq 0 ]]; then
      return 0
    fi

    sleep 1
  done

  return 1
}

cleanup() {
  if ! find_profile_pids | grep -q .; then
    return 0
  fi

  log "Stopping profiler (SIGINT)"
  signal_profile_pids INT
  if wait_for_profile_exit; then
    return 0
  fi

  if ! find_profile_pids | grep -q .; then
    return 0
  fi

  log "Profiler still running, sending SIGTERM"
  signal_profile_pids TERM
  if wait_for_profile_exit; then
    return 0
  fi

  if ! find_profile_pids | grep -q .; then
    return 0
  fi

  log "Profiler still running, sending SIGKILL"
  signal_profile_pids KILL
}
trap cleanup INT TERM

run_radclient_burst() {
  local radclient_path
  local radclient_cmd
  local payload

  if [[ -n "$RADCLIENT_BIN" && -x "$RADCLIENT_BIN" ]]; then
    radclient_path="$RADCLIENT_BIN"
  elif [[ -x "$ROOT_DIR/scripts/bin/radclient" ]]; then
    radclient_path="$ROOT_DIR/scripts/bin/radclient"
  elif [[ -x "$ROOT_DIR/build/bin/local/radclient" ]]; then
    radclient_path="$ROOT_DIR/build/bin/local/radclient"
  elif [[ -x "$ROOT_DIR/build/bin/radclient" ]]; then
    radclient_path="$ROOT_DIR/build/bin/radclient"
  elif command -v radclient >/dev/null 2>&1; then
    radclient_path="$(command -v radclient)"
  else
    printf 'ERROR: could not find radclient; use --radclient-bin PATH\n' >&2
    exit 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s -c %s %s auth %q <<< %q\n' \
      "$radclient_path" "$RADCLIENT_COUNT" "$RADCLIENT_SERVER" "$RADCLIENT_SECRET" \
      "User-Name = ${RADCLIENT_USER_PREFIX}, User-Password = ${RADCLIENT_PASSWORD}"
    record_cmd_str "${radclient_path} -c ${RADCLIENT_COUNT} ${RADCLIENT_SERVER} auth ${RADCLIENT_SECRET} <<< \"User-Name = ${RADCLIENT_USER_PREFIX}, User-Password = ${RADCLIENT_PASSWORD}\""
    return 0
  fi

  payload="User-Name = ${RADCLIENT_USER_PREFIX}, User-Password = ${RADCLIENT_PASSWORD}"
  radclient_cmd=("$radclient_path" "-c" "$RADCLIENT_COUNT")
  if [[ "$RADCLIENT_RATE" -gt 0 ]]; then
    radclient_cmd+=("-n" "$RADCLIENT_RATE")
  fi
  radclient_cmd+=("$RADCLIENT_SERVER" "auth" "$RADCLIENT_SECRET")
  record_cmd_str "printf '%s\\n' '${payload}' | $(printf '%q ' "${radclient_cmd[@]}")"

  if ! printf '%s\n' "$payload" | "${radclient_cmd[@]}"; then
    log "radclient exited non-zero (timeouts/errors); continuing to preserve profiling output"
  fi
}

callgrind_ctl() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  record_cmd callgrind_control "$@"

  if ! callgrind_control "$@" >/dev/null 2>&1; then
    log "callgrind_control failed for: $*"
    return 1
  fi

  return 0
}

start_workload_collection() {
  if [[ "$SKIP_STARTUP" -eq 0 ]]; then
    return 0
  fi

  log "Enabling callgrind collection at workload boundary"
  callgrind_ctl -z || true
  callgrind_ctl -i on || true
}

dump_workload_collection() {
  if [[ "$SKIP_STARTUP" -eq 0 ]]; then
    return 0
  fi

  log "Requesting callgrind dump after workload"
  callgrind_ctl --dump=workload || true
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$SKIP_STARTUP" -eq 1 ]]; then
    record_cmd valgrind "${VALGRIND_ARGS[@]}" --instr-atstart=no --callgrind-out-file="$out_pattern" "$RADIUSD_BIN" "${RADIUSD_ARGS[@]}"
  else
    record_cmd valgrind "${VALGRIND_ARGS[@]}" --callgrind-out-file="$out_pattern" "$RADIUSD_BIN" "${RADIUSD_ARGS[@]}"
  fi
  printf '[dry-run] '
  if [[ "$SKIP_STARTUP" -eq 1 ]]; then
    printf '%q ' valgrind "${VALGRIND_ARGS[@]}" --instr-atstart=no --callgrind-out-file="$out_pattern" "$RADIUSD_BIN" "${RADIUSD_ARGS[@]}"
  else
    printf '%q ' valgrind "${VALGRIND_ARGS[@]}" --callgrind-out-file="$out_pattern" "$RADIUSD_BIN" "${RADIUSD_ARGS[@]}"
  fi
  printf '\n'

  if [[ -n "$WORKLOAD_CMD" ]]; then
    if [[ "$STARTUP_DELAY" -gt 0 ]]; then
      log "Would wait ${STARTUP_DELAY}s for server startup"
    fi
    log "Would run workload command"
    record_cmd bash -lc "$WORKLOAD_CMD"
    printf '[dry-run] %s\n' "$WORKLOAD_CMD"
  elif [[ "$WORKLOAD_RADCLIENT_BURST" -eq 1 ]]; then
    if [[ "$STARTUP_DELAY" -gt 0 ]]; then
      log "Would wait ${STARTUP_DELAY}s for server startup"
    fi
    if [[ "$SKIP_STARTUP" -eq 1 ]]; then
      log "Would run: callgrind_control -z <pid>; callgrind_control -i on <pid>"
      record_cmd callgrind_control -z "<pid>"
      record_cmd callgrind_control -i on "<pid>"
    fi
    log "Would send ${RADCLIENT_COUNT} Access-Request packets via radclient"
    run_radclient_burst
    if [[ "$SKIP_STARTUP" -eq 1 ]]; then
      log "Would run: callgrind_control --dump=workload <pid>"
      record_cmd callgrind_control --dump=workload "<pid>"
    fi
  fi

  if [[ "$RUN_SECONDS" -gt 0 ]]; then
    log "Would profile for ${RUN_SECONDS} seconds and then stop"
  else
    log "Would keep profiling until manually stopped"
  fi

  log "Dry run complete"
  exit 0
fi

runtime_valgrind_args=("${VALGRIND_ARGS[@]}")
if [[ "$SKIP_STARTUP" -eq 1 ]]; then
  runtime_valgrind_args+=("--instr-atstart=no")
fi

record_cmd valgrind "${runtime_valgrind_args[@]}" --callgrind-out-file="$out_pattern" "$RADIUSD_BIN" "${RADIUSD_ARGS[@]}"
valgrind "${runtime_valgrind_args[@]}" --callgrind-out-file="$out_pattern" "$RADIUSD_BIN" "${RADIUSD_ARGS[@]}" &
vg_pid=$!

if [[ -n "$WORKLOAD_CMD" ]]; then
  if [[ "$STARTUP_DELAY" -gt 0 ]]; then
    log "Waiting ${STARTUP_DELAY}s for server startup"
    sleep "$STARTUP_DELAY"
  fi
  start_workload_collection
  log "Running workload command"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$WORKLOAD_CMD"
  else
    record_cmd bash -lc "$WORKLOAD_CMD"
    bash -lc "$WORKLOAD_CMD"
  fi
  dump_workload_collection
elif [[ "$WORKLOAD_RADCLIENT_BURST" -eq 1 ]]; then
  if [[ "$STARTUP_DELAY" -gt 0 ]]; then
    log "Waiting ${STARTUP_DELAY}s for server startup"
    sleep "$STARTUP_DELAY"
  fi
  start_workload_collection
  log "Sending ${RADCLIENT_COUNT} Access-Request packets via radclient"
  run_radclient_burst
  dump_workload_collection
fi

if [[ "$RUN_SECONDS" -gt 0 ]]; then
  log "Profiling for ${RUN_SECONDS} seconds"
  record_cmd sleep "$RUN_SECONDS"
  sleep "$RUN_SECONDS"
  cleanup
  wait "$vg_pid" || true
else
  log "Profiler is running (pid ${vg_pid}). Press Ctrl-C to stop, or stop radiusd manually."
  wait "$vg_pid" || true
fi

trap - INT TERM

expected_file="${out_pattern//%p/$vg_pid}"
if [[ -s "$expected_file" ]]; then
  out_file="$expected_file"
else
  out_file=""
  best_size=-1
  while IFS= read -r -d '' candidate_file; do
    candidate_size="$(wc -c < "$candidate_file" | tr -d ' ')"
    if [[ "$candidate_size" -gt "$best_size" ]]; then
      best_size="$candidate_size"
      out_file="$candidate_file"
    fi
  done < <(find "$OUT_DIR" -maxdepth 1 -type f -name "callgrind.${OUT_PREFIX}.${stamp}*" -size +0c -print0)
fi

if [[ -z "${out_file:-}" || ! -f "$out_file" ]]; then
  out_file="$(find "$OUT_DIR" -maxdepth 1 -type f -name "callgrind.${OUT_PREFIX}.${stamp}*" -print | sort | tail -n1)"
fi

if [[ -z "${out_file:-}" || ! -f "$out_file" ]]; then
  printf 'ERROR: could not find callgrind output file in %s (pattern: callgrind.%s.%s*)\n' "$OUT_DIR" "$OUT_PREFIX" "$stamp" >&2
  exit 1
fi

if [[ ! -s "$out_file" ]]; then
  log "WARNING: callgrind output file is empty: $out_file"
  log "This can happen when radiusd exits before callgrind collects samples."
fi

log "Callgrind output: $out_file"
log "Top symbols preview"
record_cmd callgrind_annotate "$out_file"
if ! callgrind_annotate "$out_file" | sed -n '1,40p'; then
  log "callgrind_annotate failed, but raw output exists and can be opened in qcachegrind"
fi

if [[ "$OPEN_QCACHEGRIND" -eq 1 ]]; then
  require_cmd qcachegrind
  log "Opening qcachegrind"
  run_cmd qcachegrind "$out_file"
else
  log "Open with: qcachegrind $out_file"
fi
