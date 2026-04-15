#!/bin/bash
set -euo pipefail

MODE=""
RUN_ID="${DOCKER_TEST_RUN_ID:-$(date +%s)}"
STATE_DIR="${DOCKER_TEST_STATE_DIR:-/tmp/docker-runtime-test-$RUN_ID}"
STATE_FILE="$STATE_DIR/state.env"
VERBOSE="${DOCKER_TEST_VERBOSE:-false}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-false}"

DOCKER_BIN="${DOCKER_BIN:-docker}"
DOCKER_COMPOSE_BIN="${DOCKER_COMPOSE_BIN:-}"
COMPOSE_MODE=""

REPO_URL="${REPO_URL:-https://github.com/niteshiftdev/niteshift-docker-test.git}"
APP_DIR="${APP_DIR:-/tmp/niteshift-docker-test}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:9090/health}"
STATS_URL="${STATS_URL:-http://127.0.0.1:8000/stats}"
ITEMS_URL="${ITEMS_URL:-http://127.0.0.1:8000/items}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-2400}"
STATS_TIMEOUT_SECONDS="${STATS_TIMEOUT_SECONDS:-120}"
STATE_KEY=""

SETUP_LOG_PATH="$STATE_DIR/repo-setup.log"

CAP_NETWORK_NAME="docker-cap-net-$RUN_ID"
CAP_REDIS_NAME="docker-cap-redis-$RUN_ID"
CAP_REDIS_HEALTH_NAME="docker-cap-redis-health-$RUN_ID"
CAP_ALPINE_NAME="docker-cap-alpine-$RUN_ID"
CAP_MEM_BRIDGE_NAME="docker-cap-mem-bridge-$RUN_ID"
CAP_MEM_HOST_NAME="docker-cap-mem-host-$RUN_ID"
CAP_VOLUME_NAME="docker-cap-volume-$RUN_ID"

SIMPLE_NETWORK_NAME="docker-simple-net-$RUN_ID"
SIMPLE_REDIS_NAME="docker-simple-redis-$RUN_ID"
SIMPLE_WRITER_NAME="docker-simple-writer-$RUN_ID"
SIMPLE_VOLUME_NAME="docker-simple-volume-$RUN_ID"
SIMPLE_MARKER="simple-marker-$RUN_ID"
SIMPLE_MARKER_PATH="/data/persist.txt"
SIMPLE_REDIS_KEY="simple:key:$RUN_ID"
SIMPLE_REDIS_VALUE="simple-value-$RUN_ID"
SIMPLE_REDIS_DIR="/tmp/redis-state"
REPO_MYSQL_MARKER="repo-mysql-$RUN_ID"
REPO_POSTGRES_MARKER="repo-postgres-$RUN_ID"
REPO_POSTGRES_MARKER_TABLE="docker_runtime_markers"

RESULT_LABELS=()
RESULT_STATUSES=()
RESULT_DETAILS=()
PASS_COUNT=0
FAIL_COUNT=0

declare -a DOCKER_BIN_ARR=()
declare -a DOCKER_COMPOSE_BIN_ARR=()

usage() {
  cat <<'EOF'
Usage:
  ./test-docker-runtime.sh --mode <mode> [options]

Modes:
  capabilities   Run a generic Docker-in-Docker capability battery
  simple-setup   Create a tiny Docker setup intended to survive provider suspend/resume
  simple-verify  Verify the tiny Docker setup after provider resume
  repo-setup     Clone and start niteshift-docker-test, then run real health/job checks
  repo-verify    Verify niteshift-docker-test after provider resume
  state-get      Print a saved state variable value

Options:
  --mode MODE                    Mode to run
  --run-id ID                    Stable run id for setup/verify pairs
  --state-dir PATH               Directory for shared state between setup/verify phases
  --docker-bin "..."             Docker command to use (default: docker)
  --docker-compose-bin "..."     Compose command override
  --repo-url URL                 Repository to use for repo modes
  --app-dir PATH                 Checkout directory for repo modes
  --health-url URL               Health endpoint for repo modes
  --stats-url URL                Stats endpoint for repo modes
  --items-url URL                Items endpoint for repo modes
  --health-timeout-seconds N     Health wait timeout for repo modes
  --stats-timeout-seconds N      Stats wait timeout for repo modes
  --state-key KEY                State variable name for state-get mode
  --keep-artifacts               Skip cleanup for capability mode
  --restart-stopped-containers   Try to start saved simple containers before verify checks
  --verbose                      Print command traces
  --help                         Show this help
EOF
}

log() {
  printf '%s\n' "$*"
}

log_phase() {
  log
  log "=== $* ==="
}

log_step() {
  log "-- $*"
}

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

duration_ms() {
  python3 - "$1" "$2" <<'PY'
import sys
print(int(sys.argv[2]) - int(sys.argv[1]))
PY
}

print_cmd() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
}

run_cmd() {
  if [[ "$VERBOSE" == "true" ]]; then
    print_cmd "$@"
  fi
  "$@"
}

run_capture_cmd() {
  local output_file="$1"
  shift
  if [[ "$VERBOSE" == "true" ]]; then
    print_cmd "$@"
  fi
  "$@" >"$output_file" 2>&1
}

parse_args() {
  local restart_stopped_containers="${RESTART_STOPPED_CONTAINERS:-false}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="$2"
        shift 2
        ;;
      --run-id)
        RUN_ID="$2"
        STATE_DIR="/tmp/docker-runtime-test-$RUN_ID"
        STATE_FILE="$STATE_DIR/state.env"
        SETUP_LOG_PATH="$STATE_DIR/repo-setup.log"
        CAP_NETWORK_NAME="docker-cap-net-$RUN_ID"
        CAP_REDIS_NAME="docker-cap-redis-$RUN_ID"
        CAP_REDIS_HEALTH_NAME="docker-cap-redis-health-$RUN_ID"
        CAP_ALPINE_NAME="docker-cap-alpine-$RUN_ID"
        CAP_MEM_BRIDGE_NAME="docker-cap-mem-bridge-$RUN_ID"
        CAP_MEM_HOST_NAME="docker-cap-mem-host-$RUN_ID"
        CAP_VOLUME_NAME="docker-cap-volume-$RUN_ID"
        SIMPLE_NETWORK_NAME="docker-simple-net-$RUN_ID"
        SIMPLE_REDIS_NAME="docker-simple-redis-$RUN_ID"
        SIMPLE_WRITER_NAME="docker-simple-writer-$RUN_ID"
        SIMPLE_VOLUME_NAME="docker-simple-volume-$RUN_ID"
        SIMPLE_MARKER="simple-marker-$RUN_ID"
        SIMPLE_REDIS_KEY="simple:key:$RUN_ID"
        SIMPLE_REDIS_VALUE="simple-value-$RUN_ID"
        REPO_MYSQL_MARKER="repo-mysql-$RUN_ID"
        REPO_POSTGRES_MARKER="repo-postgres-$RUN_ID"
        REPO_POSTGRES_MARKER_TABLE="docker_runtime_markers"
        shift 2
        ;;
      --state-dir)
        STATE_DIR="$2"
        STATE_FILE="$STATE_DIR/state.env"
        SETUP_LOG_PATH="$STATE_DIR/repo-setup.log"
        shift 2
        ;;
      --docker-bin)
        DOCKER_BIN="$2"
        shift 2
        ;;
      --docker-compose-bin)
        DOCKER_COMPOSE_BIN="$2"
        shift 2
        ;;
      --repo-url)
        REPO_URL="$2"
        shift 2
        ;;
      --app-dir)
        APP_DIR="$2"
        shift 2
        ;;
      --health-url)
        HEALTH_URL="$2"
        shift 2
        ;;
      --stats-url)
        STATS_URL="$2"
        shift 2
        ;;
      --items-url)
        ITEMS_URL="$2"
        shift 2
        ;;
      --health-timeout-seconds)
        HEALTH_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --stats-timeout-seconds)
        STATS_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --state-key)
        STATE_KEY="$2"
        shift 2
        ;;
      --keep-artifacts)
        KEEP_ARTIFACTS="true"
        shift
        ;;
      --restart-stopped-containers)
        restart_stopped_containers="true"
        shift
        ;;
      --verbose)
        VERBOSE="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
  RESTART_STOPPED_CONTAINERS="$restart_stopped_containers"
}

record_result() {
  local label="$1"
  local status="$2"
  local detail="$3"

  RESULT_LABELS+=("$label")
  RESULT_STATUSES+=("$status")
  RESULT_DETAILS+=("$detail")

  if [[ "$status" == "PASS" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  printf '%-32s %s' "$label" "$status"
  if [[ -n "$detail" ]]; then
    printf '  %s' "$detail"
  fi
  printf '\n'
}

print_summary() {
  log
  log "=== Summary ==="
  local idx
  for idx in "${!RESULT_LABELS[@]}"; do
    printf '%-32s %s' "${RESULT_LABELS[$idx]}" "${RESULT_STATUSES[$idx]}"
    if [[ -n "${RESULT_DETAILS[$idx]}" ]]; then
      printf '  %s' "${RESULT_DETAILS[$idx]}"
    fi
    printf '\n'
  done
  log
  log "Passes: $PASS_COUNT"
  log "Fails: $FAIL_COUNT"
  log "State dir: $STATE_DIR"
}

init_command_arrays() {
  read -r -a DOCKER_BIN_ARR <<< "$DOCKER_BIN"
  if [[ -z "${DOCKER_BIN_ARR[*]:-}" ]]; then
    echo "Invalid docker command: $DOCKER_BIN" >&2
    exit 1
  fi
}

docker_cmd() {
  run_cmd "${DOCKER_BIN_ARR[@]}" "$@"
}

docker_cmd_quiet() {
  "${DOCKER_BIN_ARR[@]}" "$@"
}

ensure_compose_ready() {
  if [[ -n "$DOCKER_COMPOSE_BIN" ]]; then
    read -r -a DOCKER_COMPOSE_BIN_ARR <<< "$DOCKER_COMPOSE_BIN"
    if [[ -z "${DOCKER_COMPOSE_BIN_ARR[*]:-}" ]]; then
      echo "Invalid compose command: $DOCKER_COMPOSE_BIN" >&2
      exit 1
    fi
    COMPOSE_MODE="external"
    return
  fi

  if docker_cmd_quiet compose version >/dev/null 2>&1; then
    COMPOSE_MODE="docker-subcommand"
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    if [[ "${DOCKER_BIN_ARR[0]:-}" == "sudo" ]]; then
      DOCKER_COMPOSE_BIN_ARR=(sudo docker-compose)
    else
      DOCKER_COMPOSE_BIN_ARR=(docker-compose)
    fi
    COMPOSE_MODE="external"
    return
  fi

  echo "Docker Compose is not available. Pass --docker-compose-bin if needed." >&2
  exit 1
}

docker_compose_cmd() {
  if [[ "$COMPOSE_MODE" == "docker-subcommand" ]]; then
    docker_cmd compose "$@"
    return
  fi

  run_cmd "${DOCKER_COMPOSE_BIN_ARR[@]}" "$@"
}

docker_compose_cmd_quiet() {
  if [[ "$COMPOSE_MODE" == "docker-subcommand" ]]; then
    docker_cmd_quiet compose "$@"
    return
  fi

  "${DOCKER_COMPOSE_BIN_ARR[@]}" "$@"
}

save_state_var() {
  local key="$1"
  local value="$2"
  mkdir -p "$STATE_DIR"
  printf '%s=%q\n' "$key" "$value" >> "$STATE_FILE"
}

reset_state_file() {
  mkdir -p "$STATE_DIR"
  : >"$STATE_FILE"
}

load_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "State file not found: $STATE_FILE" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

ensure_common_prerequisites() {
  mkdir -p "$STATE_DIR"
  init_command_arrays
  if [[ "$MODE" == "state-get" ]]; then
    return
  fi
  if ! docker_cmd_quiet info >/dev/null 2>&1; then
    echo "Docker is not reachable via '$DOCKER_BIN'. Wrapper should bring dockerd up first." >&2
    exit 1
  fi
}

ensure_repo_prerequisites() {
  command -v git >/dev/null 2>&1 || {
    echo "git is required for repo modes" >&2
    exit 1
  }
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required for repo modes" >&2
    exit 1
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required for repo modes" >&2
    exit 1
  }
  ensure_compose_ready
}

print_environment() {
  log "=== Docker Runtime Test ==="
  log "Mode: $MODE"
  log "Run ID: $RUN_ID"
  log "State dir: $STATE_DIR"
  log "Docker command: $DOCKER_BIN"
  if [[ -n "$DOCKER_COMPOSE_BIN" ]]; then
    log "Compose command: $DOCKER_COMPOSE_BIN"
  fi
  log "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  log "Kernel: $(uname -srmo)"
  log
  docker_cmd_quiet version --format 'Client={{.Client.Version}} Server={{.Server.Version}}' 2>/dev/null || true
  docker_cmd_quiet info --format 'StorageDriver={{.Driver}} CgroupDriver={{.CgroupDriver}} CgroupVersion={{.CgroupVersion}} Kernel={{.KernelVersion}} OS={{.OperatingSystem}}' 2>/dev/null || true
  log
}

wait_for_running() {
  local container_name="$1"
  local attempts="${2:-20}"

  for _ in $(seq 1 "$attempts"); do
    if [[ "$(docker_cmd_quiet inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" == "true" ]]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

container_exists() {
  local container_name="$1"
  docker_cmd_quiet inspect "$container_name" >/dev/null 2>&1
}

network_exists() {
  local network_name="$1"
  docker_cmd_quiet network inspect "$network_name" >/dev/null 2>&1
}

ensure_simple_network_for_restart() {
  local output_file="$STATE_DIR/simple_resume_network_restore.out"

  if network_exists "$SIMPLE_NETWORK_NAME"; then
    return 0
  fi

  if run_capture_cmd "$output_file" "${DOCKER_BIN_ARR[@]}" network create "$SIMPLE_NETWORK_NAME"; then
    record_result "simple_resume_network_restore" "PASS" "$SIMPLE_NETWORK_NAME"
    return 0
  fi

  record_result "simple_resume_network_restore" "FAIL" "$(summarize_output_file "$output_file")"
  return 1
}

start_saved_container_if_needed() {
  local container_name="$1"
  local label="$2"
  local output_file="$STATE_DIR/${container_name}.start.out"
  local running_state=""

  if ! container_exists "$container_name"; then
    record_result "$label" "FAIL" "missing container"
    return 0
  fi

  running_state="$(docker_cmd_quiet inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)"
  if [[ "$running_state" == "true" ]]; then
    record_result "$label" "PASS" "already running"
    return 0
  fi

  if [[ "${RESTART_STOPPED_CONTAINERS:-false}" != "true" ]]; then
    return 0
  fi

  if run_capture_cmd "$output_file" "${DOCKER_BIN_ARR[@]}" start "$container_name"; then
    if wait_for_running "$container_name" 20; then
      record_result "$label" "PASS" "container restarted"
    else
      record_result "$label" "FAIL" "container did not reach running state"
    fi
    return 0
  fi

  record_result "$label" "FAIL" "$(summarize_output_file "$output_file")"
}

summarize_output_file() {
  local output_file="$1"
  local detail=""

  detail="$(grep -E 'permission denied|setns|OCI runtime exec failed|Error response from daemon|health status=|Could not resolve host|Temporary failure in name resolution|bad address|connection refused' "$output_file" | tail -n 1 || true)"
  if [[ -z "$detail" ]]; then
    detail="$(tail -n 5 "$output_file" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/ $//')"
  fi

  printf '%s' "$detail"
}

cleanup_capabilities_artifacts() {
  if [[ "$KEEP_ARTIFACTS" == "true" ]]; then
    return
  fi

  docker_cmd_quiet rm -f \
    "$CAP_REDIS_NAME" \
    "$CAP_REDIS_HEALTH_NAME" \
    "$CAP_ALPINE_NAME" \
    "$CAP_MEM_BRIDGE_NAME" \
    "$CAP_MEM_HOST_NAME" >/dev/null 2>&1 || true
  docker_cmd_quiet network rm "$CAP_NETWORK_NAME" >/dev/null 2>&1 || true
  docker_cmd_quiet volume rm -f "$CAP_VOLUME_NAME" >/dev/null 2>&1 || true
}

test_container_start() {
  local label="$1"
  local container_name="$2"
  shift 2
  local output_file="$STATE_DIR/$label.out"

  docker_cmd_quiet rm -f "$container_name" >/dev/null 2>&1 || true
  if run_capture_cmd "$output_file" "${DOCKER_BIN_ARR[@]}" run -d --name "$container_name" "$@"; then
    if wait_for_running "$container_name" 15; then
      record_result "$label" "PASS" "container started"
    else
      record_result "$label" "FAIL" "container never reached running state"
    fi
  else
    record_result "$label" "FAIL" "$(summarize_output_file "$output_file")"
  fi
}

test_bridge_ping() {
  local label="$1"
  local network_name="$2"
  local host_name="$3"
  local output_file="$STATE_DIR/$label.out"

  local attempt_output=""
  for _ in $(seq 1 15); do
    if run_capture_cmd \
      "$output_file" \
      "${DOCKER_BIN_ARR[@]}" run --rm --network "$network_name" redis:7 redis-cli -h "$host_name" ping; then
      record_result "$label" "PASS" "$(tr -d '\r' <"$output_file" | tail -n 1)"
      return
    fi

    attempt_output="$(summarize_output_file "$output_file")"
    sleep 1
  done

  record_result "$label" "FAIL" "$attempt_output"
}

test_named_volume_roundtrip() {
  local label="$1"
  local output_file="$STATE_DIR/$label.out"

  docker_cmd_quiet volume rm -f "$CAP_VOLUME_NAME" >/dev/null 2>&1 || true
  docker_cmd_quiet volume create "$CAP_VOLUME_NAME" >/dev/null

  if ! run_capture_cmd \
    "$output_file" \
    "${DOCKER_BIN_ARR[@]}" run --rm --mount "source=$CAP_VOLUME_NAME,target=/data" alpine:3.20 \
      sh -lc "echo volume-$RUN_ID > /data/check.txt"; then
    record_result "$label" "FAIL" "$(summarize_output_file "$output_file")"
    return
  fi

  if run_capture_cmd \
    "$output_file" \
    "${DOCKER_BIN_ARR[@]}" run --rm --mount "source=$CAP_VOLUME_NAME,target=/data" alpine:3.20 \
      cat /data/check.txt; then
    local detail
    detail="$(tr -d '\r' <"$output_file" | tail -n 1)"
    if [[ "$detail" == "volume-$RUN_ID" ]]; then
      record_result "$label" "PASS" "named volume read/write works"
    else
      record_result "$label" "FAIL" "unexpected content: $detail"
    fi
  else
    record_result "$label" "FAIL" "$(summarize_output_file "$output_file")"
  fi
}

run_capabilities_mode() {
  trap cleanup_capabilities_artifacts EXIT

  print_environment

  record_result "docker_access" "PASS" "$DOCKER_BIN"
  record_result \
    "docker_version" \
    "PASS" \
    "client=$(docker_cmd_quiet version --format '{{.Client.Version}}' 2>/dev/null || printf '?') server=$(docker_cmd_quiet version --format '{{.Server.Version}}' 2>/dev/null || printf '?')"

  if docker_cmd_quiet network rm "$CAP_NETWORK_NAME" >/dev/null 2>&1; then
    :
  fi
  docker_cmd network create "$CAP_NETWORK_NAME" >/dev/null
  record_result "bridge_network_create" "PASS" "$CAP_NETWORK_NAME"

  test_container_start "redis_bridge_start" "$CAP_REDIS_NAME" --network "$CAP_NETWORK_NAME" redis:7
  test_bridge_ping "bridge_dns_ping" "$CAP_NETWORK_NAME" "$CAP_REDIS_NAME"

  local output_file="$STATE_DIR/redis_exec_ping.out"
  if run_capture_cmd "$output_file" "${DOCKER_BIN_ARR[@]}" exec "$CAP_REDIS_NAME" redis-cli ping; then
    record_result "redis_exec_ping" "PASS" "$(tr -d '\r' <"$output_file" | tail -n 1)"
  else
    record_result "redis_exec_ping" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  docker_cmd_quiet rm -f "$CAP_REDIS_HEALTH_NAME" >/dev/null 2>&1 || true
  output_file="$STATE_DIR/redis_healthcheck.out"
  if run_capture_cmd \
    "$output_file" \
    "${DOCKER_BIN_ARR[@]}" run -d --name "$CAP_REDIS_HEALTH_NAME" \
      --health-cmd "redis-cli ping || exit 1" \
      --health-interval 2s \
      --health-timeout 1s \
      --health-retries 10 \
      redis:7; then
    health_status="unknown"
    for _ in $(seq 1 20); do
      health_status="$(docker_cmd_quiet inspect -f '{{.State.Health.Status}}' "$CAP_REDIS_HEALTH_NAME" 2>/dev/null || true)"
      if [[ "$health_status" == "healthy" ]]; then
        break
      fi
      sleep 1
    done
    if [[ "$health_status" == "healthy" ]]; then
      record_result "redis_healthcheck" "PASS" "health status=healthy"
    else
      record_result "redis_healthcheck" "FAIL" "health status=$health_status"
    fi
  else
    record_result "redis_healthcheck" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  test_container_start "alpine_bridge_start" "$CAP_ALPINE_NAME" --network "$CAP_NETWORK_NAME" alpine:3.20 sleep 600
  test_container_start "memcached_bridge_start" "$CAP_MEM_BRIDGE_NAME" memcached:1.6
  test_container_start "memcached_host_start" "$CAP_MEM_HOST_NAME" --network host memcached:1.6 memcached -p 11222

  output_file="$STATE_DIR/container_http_egress.out"
  if run_capture_cmd \
    "$output_file" \
    timeout 15 "${DOCKER_BIN_ARR[@]}" run --rm busybox:1.36 sh -lc "wget -qO- http://example.com | grep -qi example"; then
    record_result "container_http_egress" "PASS" "outbound HTTP works"
  else
    record_result "container_http_egress" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  test_named_volume_roundtrip "named_volume_rw"

  log
  log "=== Capability Containers ==="
  docker_cmd ps --format 'table {{.Names}}\t{{.Status}}'
  print_summary

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
}

run_simple_setup_mode() {
  print_environment
  reset_state_file

  docker_cmd_quiet rm -f "$SIMPLE_REDIS_NAME" "$SIMPLE_WRITER_NAME" >/dev/null 2>&1 || true
  docker_cmd_quiet network rm "$SIMPLE_NETWORK_NAME" >/dev/null 2>&1 || true
  docker_cmd_quiet volume rm -f "$SIMPLE_VOLUME_NAME" >/dev/null 2>&1 || true

  docker_cmd network create "$SIMPLE_NETWORK_NAME" >/dev/null
  record_result "simple_network_create" "PASS" "$SIMPLE_NETWORK_NAME"

  docker_cmd volume create "$SIMPLE_VOLUME_NAME" >/dev/null
  record_result "simple_volume_create" "PASS" "$SIMPLE_VOLUME_NAME"

  local output_file="$STATE_DIR/simple_redis_start.out"
  if run_capture_cmd \
    "$output_file" \
    "${DOCKER_BIN_ARR[@]}" run -d --name "$SIMPLE_REDIS_NAME" --restart unless-stopped \
      --network "$SIMPLE_NETWORK_NAME" redis:7 \
      sh -lc "mkdir -p '$SIMPLE_REDIS_DIR' && exec redis-server --appendonly yes --dir '$SIMPLE_REDIS_DIR' --save 1 1"; then
    if wait_for_running "$SIMPLE_REDIS_NAME" 20; then
      record_result "simple_redis_start" "PASS" "container started"
    else
      record_result "simple_redis_start" "FAIL" "container never reached running state"
    fi
  else
    record_result "simple_redis_start" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  output_file="$STATE_DIR/simple_writer_start.out"
  if run_capture_cmd \
    "$output_file" \
    "${DOCKER_BIN_ARR[@]}" run -d --name "$SIMPLE_WRITER_NAME" --restart unless-stopped --network "$SIMPLE_NETWORK_NAME" \
      --mount "source=$SIMPLE_VOLUME_NAME,target=/data" alpine:3.20 sleep 600; then
    if wait_for_running "$SIMPLE_WRITER_NAME" 20; then
      record_result "simple_writer_start" "PASS" "container started"
    else
      record_result "simple_writer_start" "FAIL" "container never reached running state"
    fi
  else
    record_result "simple_writer_start" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  test_bridge_ping "simple_bridge_ping" "$SIMPLE_NETWORK_NAME" "$SIMPLE_REDIS_NAME"

  output_file="$STATE_DIR/simple_redis_write.out"
  if run_capture_cmd \
    "$output_file" \
    "${DOCKER_BIN_ARR[@]}" exec "$SIMPLE_REDIS_NAME" sh -lc \
      "redis-cli SET $(printf '%q' "$SIMPLE_REDIS_KEY") $(printf '%q' "$SIMPLE_REDIS_VALUE") >/tmp/simple-redis-set.out && redis-cli SAVE >/tmp/simple-redis-save.out && cat /tmp/simple-redis-set.out"; then
    local redis_set_result
    redis_set_result="$(tr -d '\r' <"$output_file" | tail -n 1)"
    if [[ "$redis_set_result" == "OK" ]]; then
      record_result "simple_redis_write" "PASS" "$SIMPLE_REDIS_KEY=$SIMPLE_REDIS_VALUE"
    else
      record_result "simple_redis_write" "FAIL" "unexpected redis response: $redis_set_result"
    fi
  else
    record_result "simple_redis_write" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  output_file="$STATE_DIR/simple_volume_write.out"
  if run_capture_cmd \
    "$output_file" \
    "${DOCKER_BIN_ARR[@]}" exec "$SIMPLE_WRITER_NAME" sh -lc "printf '%s\n' '$SIMPLE_MARKER' > '$SIMPLE_MARKER_PATH' && sync"; then
    record_result "simple_volume_write" "PASS" "$SIMPLE_MARKER"
  else
    record_result "simple_volume_write" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  save_state_var "SIMPLE_NETWORK_NAME" "$SIMPLE_NETWORK_NAME"
  save_state_var "SIMPLE_REDIS_NAME" "$SIMPLE_REDIS_NAME"
  save_state_var "SIMPLE_WRITER_NAME" "$SIMPLE_WRITER_NAME"
  save_state_var "SIMPLE_VOLUME_NAME" "$SIMPLE_VOLUME_NAME"
  save_state_var "SIMPLE_MARKER" "$SIMPLE_MARKER"
  save_state_var "SIMPLE_MARKER_PATH" "$SIMPLE_MARKER_PATH"
  save_state_var "SIMPLE_REDIS_KEY" "$SIMPLE_REDIS_KEY"
  save_state_var "SIMPLE_REDIS_VALUE" "$SIMPLE_REDIS_VALUE"
  save_state_var "RUN_ID" "$RUN_ID"
  save_state_var "SIMPLE_SETUP_FAIL_COUNT" "$FAIL_COUNT"
  record_result "simple_state_saved" "PASS" "$STATE_FILE"

  log
  log "=== Simple Setup Containers ==="
  docker_cmd ps --format 'table {{.Names}}\t{{.Status}}'
  print_summary

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    log "Simple setup recorded failures, but returning success so the wrapper can continue to lifecycle verification."
  fi
}

run_simple_verify_mode() {
  print_environment
  load_state

  if [[ "${RESTART_STOPPED_CONTAINERS:-false}" == "true" ]]; then
    ensure_simple_network_for_restart || true
    start_saved_container_if_needed "$SIMPLE_REDIS_NAME" "simple_resume_redis_restart"
    start_saved_container_if_needed "$SIMPLE_WRITER_NAME" "simple_resume_writer_restart"
  fi

  local output_file="$STATE_DIR/simple_resume_ps.out"
  if run_capture_cmd "$output_file" "${DOCKER_BIN_ARR[@]}" ps --format '{{.Names}}'; then
    local missing_names=()
    local ps_output
    ps_output="$(cat "$output_file")"
    for name in "$SIMPLE_REDIS_NAME" "$SIMPLE_WRITER_NAME"; do
      if ! printf '%s\n' "$ps_output" | grep -Fxq "$name"; then
        missing_names+=("$name")
      fi
    done
    if [[ "${#missing_names[@]}" -eq 0 ]]; then
      record_result "simple_resume_presence" "PASS" "containers still present"
    else
      record_result "simple_resume_presence" "FAIL" "missing: ${missing_names[*]}"
    fi
  else
    record_result "simple_resume_presence" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  output_file="$STATE_DIR/simple_resume_ps_all.out"
  if run_capture_cmd \
    "$output_file" \
    "${DOCKER_BIN_ARR[@]}" ps -a --format '{{.Names}}|{{.State}}|{{.Status}}'; then
    local state_lines
    state_lines="$(cat "$output_file")"
    local -a state_details=()
    local name=""
    for name in "$SIMPLE_REDIS_NAME" "$SIMPLE_WRITER_NAME"; do
      local state_line=""
      state_line="$(printf '%s\n' "$state_lines" | grep -F "${name}|" | head -n 1 || true)"
      if [[ -n "$state_line" ]]; then
        state_details+=("$state_line")
      else
        state_details+=("$name|missing")
      fi
    done
    record_result "simple_resume_ps_all" "PASS" "$(IFS='; '; printf '%s' "${state_details[*]}")"
  else
    record_result "simple_resume_ps_all" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  output_file="$STATE_DIR/simple_resume_exec.out"
  if run_capture_cmd "$output_file" "${DOCKER_BIN_ARR[@]}" exec "$SIMPLE_REDIS_NAME" redis-cli GET "$SIMPLE_REDIS_KEY"; then
    local redis_value
    redis_value="$(tr -d '\r' <"$output_file" | tail -n 1)"
    if [[ "$redis_value" == "$SIMPLE_REDIS_VALUE" ]]; then
      record_result "simple_resume_redis_data" "PASS" "$SIMPLE_REDIS_KEY=$redis_value"
    else
      record_result "simple_resume_redis_data" "FAIL" "expected $SIMPLE_REDIS_VALUE got ${redis_value:-<empty>}"
    fi
  else
    record_result "simple_resume_redis_data" "FAIL" "$(summarize_output_file "$output_file")"
  fi

  output_file="$STATE_DIR/simple_resume_volume.out"
  if run_capture_cmd "$output_file" "${DOCKER_BIN_ARR[@]}" exec "$SIMPLE_WRITER_NAME" cat "$SIMPLE_MARKER_PATH"; then
    local persisted
    persisted="$(tr -d '\r' <"$output_file" | tail -n 1)"
    if [[ "$persisted" == "$SIMPLE_MARKER" ]]; then
      record_result "simple_resume_volume" "PASS" "$persisted"
    else
      record_result "simple_resume_volume" "FAIL" "expected $SIMPLE_MARKER got $persisted"
    fi
  else
    local exec_failure
    exec_failure="$(summarize_output_file "$output_file")"

    output_file="$STATE_DIR/simple_resume_volume_fallback.out"
    if run_capture_cmd \
      "$output_file" \
      "${DOCKER_BIN_ARR[@]}" \
      run \
      --rm \
      --mount "source=$SIMPLE_VOLUME_NAME,target=/data" \
      alpine:3.20 \
      cat \
      "$SIMPLE_MARKER_PATH"; then
      local mounted_persisted
      mounted_persisted="$(tr -d '\r' <"$output_file" | tail -n 1)"
      if [[ "$mounted_persisted" == "$SIMPLE_MARKER" ]]; then
        record_result "simple_resume_volume" "PASS" "$mounted_persisted via mounted volume fallback"
      else
        record_result "simple_resume_volume" "FAIL" "expected $SIMPLE_MARKER got $mounted_persisted"
      fi
    else
      record_result "simple_resume_volume" "FAIL" "$exec_failure; fallback: $(summarize_output_file "$output_file")"
    fi
  fi

  test_bridge_ping "simple_resume_bridge" "$SIMPLE_NETWORK_NAME" "$SIMPLE_REDIS_NAME"

  log
  log "=== Simple Resume Containers ==="
  docker_cmd ps --format 'table {{.Names}}\t{{.Status}}'
  log
  log "=== Simple Resume Containers (All) ==="
  docker_cmd ps -a --format 'table {{.Names}}\t{{.State}}\t{{.Status}}'
  print_summary

  local total_fail_count="$FAIL_COUNT"
  if [[ -n "${SIMPLE_SETUP_FAIL_COUNT:-}" ]]; then
    total_fail_count=$((total_fail_count + SIMPLE_SETUP_FAIL_COUNT))
  fi

  if [[ "$total_fail_count" -gt 0 ]]; then
    exit 1
  fi
}

http_json_request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"

  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" -H "Content-Type: application/json" --data "$body" "$url"
    return
  fi

  curl -fsS -X "$method" "$url"
}

health_is_healthy() {
  python3 - "$1" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
overall = bool(payload.get("overall"))
services = payload.get("services", [])
all_healthy = all(bool(service.get("healthy")) for service in services)
print("true" if overall and all_healthy else "false")
PY
}

parse_stats_triplet() {
  python3 - "$1" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(payload["total_items"], payload["processed_items"], payload["pending_jobs"])
PY
}

wait_for_healthy_dashboard() {
  local timeout_seconds="$1"
  local started_at
  started_at="$(date +%s)"
  local last_error="no response"

  while (( $(date +%s) - started_at < timeout_seconds )); do
    local payload=""
    if payload="$(http_json_request GET "$HEALTH_URL" 2>/dev/null)"; then
      if [[ "$(health_is_healthy "$payload")" == "true" ]]; then
        return 0
      fi
      last_error="$payload"
    else
      last_error="curl failed"
    fi
    sleep 2
  done

  echo "$last_error" >&2
  return 1
}

fetch_stats() {
  local payload
  payload="$(http_json_request GET "$STATS_URL")"
  parse_stats_triplet "$payload"
}

post_item() {
  local item_name="$1"
  http_json_request POST "$ITEMS_URL" "{\"name\":\"$item_name\"}" >/dev/null
}

wait_for_expected_stats() {
  local expected_total="$1"
  local expected_processed="$2"
  local timeout_seconds="$3"
  local ignore_pending="${4:-false}"
  local started_at
  started_at="$(date +%s)"
  local last_state="no stats"

  while (( $(date +%s) - started_at < timeout_seconds )); do
    local total_items=""
    local processed_items=""
    local pending_jobs=""
    if read -r total_items processed_items pending_jobs < <(fetch_stats 2>/dev/null); then
      last_state="total=$total_items processed=$processed_items pending=$pending_jobs"
      if [[ "$total_items" == "$expected_total" && "$processed_items" == "$expected_processed" ]]; then
        if [[ "$ignore_pending" == "true" || "$pending_jobs" == "0" ]]; then
          printf '%s %s %s\n' "$total_items" "$processed_items" "$pending_jobs"
          return 0
        fi
      fi
    fi
    sleep 1
  done

  echo "$last_state" >&2
  return 1
}

print_repo_diagnostics() {
  log
  log "=== Repo Diagnostics ==="
  if [[ -d "$APP_DIR" ]]; then
    (
      cd "$APP_DIR"
      docker_compose_cmd ps || true
      docker_compose_cmd logs --tail 80 || true
    )
  fi
  if [[ -f "$SETUP_LOG_PATH" ]]; then
    log "--- setup log tail ---"
    tail -n 120 "$SETUP_LOG_PATH" || true
  fi
}

mysql_query_capture() {
  local sql="$1"
  local output_file="$2"
  (
    cd "$APP_DIR"
    docker_compose_cmd exec -T mysql mysql -uapp -papppass testdb -Nse "$sql"
  ) >"$output_file" 2>&1
}

postgres_query_capture() {
  local sql="$1"
  local output_file="$2"
  (
    cd "$APP_DIR"
    docker_compose_cmd exec -T postgres psql -U app testdb -tA -c "$sql"
  ) >"$output_file" 2>&1
}

run_repo_compose_sequence() {
  (
    cd "$APP_DIR"
    {
      echo "==> Pulling container images..."
      docker_compose_cmd pull redis mysql nginx postgres memcached
      echo "==> Building custom images..."
      docker_compose_cmd build api worker healthcheck
      echo "==> Starting all services..."
      docker_compose_cmd up -d --wait
      echo "==> Checking data persistence (MySQL)..."
      docker_compose_cmd exec -T mysql mysql -uapp -papppass testdb -e "
        INSERT INTO items (name) VALUES ('setup-run-$(date +%s)');
        SELECT COUNT(*) AS total_setup_runs FROM items WHERE name LIKE 'setup-run-%';
      "
      echo "==> Checking data persistence (Postgres)..."
      docker_compose_cmd exec -T postgres psql -U app testdb -c "
        CREATE TABLE IF NOT EXISTS docker_runtime_probe_runs (id SERIAL PRIMARY KEY, ran_at TIMESTAMPTZ DEFAULT NOW());
        INSERT INTO docker_runtime_probe_runs DEFAULT VALUES;
        SELECT count(*) AS total_setup_runs FROM docker_runtime_probe_runs;
      "
    } >"$SETUP_LOG_PATH" 2>&1
  )
}

run_repo_setup_mode() {
  print_environment
  ensure_repo_prerequisites
  reset_state_file
  local setup_started_at
  setup_started_at="$(now_ms)"

  log_phase "Repo Setup"
  log_step "Cloning repository into $APP_DIR"
  rm -rf "$APP_DIR"
  local output_file="$STATE_DIR/repo_clone.out"
  if run_capture_cmd "$output_file" git clone --depth 1 "$REPO_URL" "$APP_DIR"; then
    record_result "repo_clone" "PASS" "$APP_DIR"
  else
    record_result "repo_clone" "FAIL" "$(summarize_output_file "$output_file")"
    print_summary
    exit 1
  fi

  log_step "Running docker compose pull/build/up"
  if run_repo_compose_sequence; then
    record_result "repo_compose_setup" "PASS" "compose pull/build/up completed"
  else
    record_result "repo_compose_setup" "FAIL" "see $SETUP_LOG_PATH"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Waiting for health endpoint at $HEALTH_URL"
  if wait_for_healthy_dashboard "$HEALTH_TIMEOUT_SECONDS"; then
    local repo_health_ms
    repo_health_ms="$(duration_ms "$setup_started_at" "$(now_ms)")"
    record_result "repo_health" "PASS" "$HEALTH_URL (${repo_health_ms}ms)"
    save_state_var "REPO_SETUP_HEALTH_MS" "$repo_health_ms"
  else
    record_result "repo_health" "FAIL" "dashboard never became healthy"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Reading initial stats from $STATS_URL"
  local total_before=""
  local processed_before=""
  local pending_before=""
  if read -r total_before processed_before pending_before < <(fetch_stats); then
    record_result "repo_stats_before" "PASS" "total=$total_before processed=$processed_before pending=$pending_before"
  else
    record_result "repo_stats_before" "FAIL" "could not read $STATS_URL"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Seeding MySQL marker data"
  output_file="$STATE_DIR/repo_mysql_marker.out"
  if mysql_query_capture \
    "INSERT INTO items (name) VALUES ('$REPO_MYSQL_MARKER'); SELECT COUNT(*) FROM items WHERE name = '$REPO_MYSQL_MARKER';" \
    "$output_file"; then
    local mysql_marker_count
    mysql_marker_count="$(tr -d '\r' <"$output_file" | tail -n 1)"
    if [[ "$mysql_marker_count" == "1" ]]; then
      record_result "repo_mysql_seed" "PASS" "$REPO_MYSQL_MARKER"
    else
      record_result "repo_mysql_seed" "FAIL" "expected 1 got ${mysql_marker_count:-<empty>}"
      print_repo_diagnostics
      print_summary
      exit 1
    fi
  else
    record_result "repo_mysql_seed" "FAIL" "$(summarize_output_file "$output_file")"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Seeding Postgres marker data"
  output_file="$STATE_DIR/repo_postgres_marker.out"
  if postgres_query_capture \
    "CREATE TABLE IF NOT EXISTS $REPO_POSTGRES_MARKER_TABLE (marker TEXT PRIMARY KEY, ran_at TIMESTAMPTZ DEFAULT NOW()); INSERT INTO $REPO_POSTGRES_MARKER_TABLE (marker) VALUES ('$REPO_POSTGRES_MARKER') ON CONFLICT (marker) DO NOTHING; SELECT COUNT(*) FROM $REPO_POSTGRES_MARKER_TABLE WHERE marker = '$REPO_POSTGRES_MARKER';" \
    "$output_file"; then
    local postgres_marker_count
    postgres_marker_count="$(tr -d '\r' <"$output_file" | tail -n 1)"
    if [[ "$postgres_marker_count" == "1" ]]; then
      record_result "repo_postgres_seed" "PASS" "$REPO_POSTGRES_MARKER"
    else
      record_result "repo_postgres_seed" "FAIL" "expected 1 got ${postgres_marker_count:-<empty>}"
      print_repo_diagnostics
      print_summary
      exit 1
    fi
  else
    record_result "repo_postgres_seed" "FAIL" "$(summarize_output_file "$output_file")"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Posting an item and waiting for worker processing"
  local item_name="repo-setup-$RUN_ID-$(date +%s)"
  if post_item "$item_name"; then
    record_result "repo_item_post" "PASS" "$item_name"
  else
    record_result "repo_item_post" "FAIL" "POST $ITEMS_URL failed"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  local total_after=""
  local processed_after=""
  local pending_after=""
  if read -r total_after processed_after pending_after < <(
    wait_for_expected_stats \
      "$((total_before + 2))" \
      "$((processed_before + 1))" \
      "$STATS_TIMEOUT_SECONDS" \
      true
  ); then
    record_result "repo_item_roundtrip" "PASS" "total=$total_after processed=$processed_after pending=$pending_after"
  else
    record_result "repo_item_roundtrip" "FAIL" "stats did not advance"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  save_state_var "APP_DIR" "$APP_DIR"
  save_state_var "REPO_URL" "$REPO_URL"
  save_state_var "REPO_EXPECTED_TOTAL_ITEMS" "$total_after"
  save_state_var "REPO_EXPECTED_PROCESSED_ITEMS" "$processed_after"
  save_state_var "REPO_EXPECTED_PENDING_JOBS" "$pending_after"
  save_state_var "REPO_MYSQL_MARKER" "$REPO_MYSQL_MARKER"
  save_state_var "REPO_POSTGRES_MARKER" "$REPO_POSTGRES_MARKER"
  save_state_var "RUN_ID" "$RUN_ID"
  record_result "repo_state_saved" "PASS" "$STATE_FILE"

  log
  log "=== Repo Services ==="
  (
    cd "$APP_DIR"
    docker_compose_cmd ps || true
  )
  print_summary
}

run_repo_verify_mode() {
  print_environment
  ensure_repo_prerequisites
  load_state
  local verify_started_at
  verify_started_at="$(now_ms)"

  log_phase "Repo Verify"
  if [[ ! -d "$APP_DIR" ]]; then
    record_result "repo_resume_checkout" "FAIL" "missing $APP_DIR"
    print_summary
    exit 1
  fi

  if [[ "${RESTART_STOPPED_CONTAINERS:-false}" == "true" ]]; then
    log_step "Running docker compose up -d --wait before verification"
    local output_file="$STATE_DIR/repo_resume_compose_restart.out"
    if (
      cd "$APP_DIR"
      docker_compose_cmd up -d --wait
    ) >"$output_file" 2>&1; then
      record_result "repo_resume_compose_restart" "PASS" "docker compose up -d --wait"
    else
      record_result "repo_resume_compose_restart" "FAIL" "$(summarize_output_file "$output_file")"
      print_repo_diagnostics
      print_summary
      exit 1
    fi
  fi

  log_step "Waiting for health endpoint at $HEALTH_URL"
  if wait_for_healthy_dashboard "$HEALTH_TIMEOUT_SECONDS"; then
    local repo_resume_health_ms
    repo_resume_health_ms="$(duration_ms "$verify_started_at" "$(now_ms)")"
    record_result "repo_resume_health" "PASS" "$HEALTH_URL (${repo_resume_health_ms}ms)"
    save_state_var "REPO_VERIFY_HEALTH_MS" "$repo_resume_health_ms"
  else
    record_result "repo_resume_health" "FAIL" "dashboard never became healthy"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Checking stats baseline after resume"
  local total_before=""
  local processed_before=""
  local pending_before=""
  if read -r total_before processed_before pending_before < <(fetch_stats); then
    if [[ "$total_before" == "$REPO_EXPECTED_TOTAL_ITEMS" && "$processed_before" == "$REPO_EXPECTED_PROCESSED_ITEMS" ]]; then
      record_result "repo_resume_baseline" "PASS" "total=$total_before processed=$processed_before pending=$pending_before"
    else
      record_result \
        "repo_resume_baseline" \
        "FAIL" \
        "expected total=$REPO_EXPECTED_TOTAL_ITEMS processed=$REPO_EXPECTED_PROCESSED_ITEMS got total=$total_before processed=$processed_before"
      print_repo_diagnostics
      print_summary
      exit 1
    fi
  else
    record_result "repo_resume_baseline" "FAIL" "could not read $STATS_URL"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Verifying MySQL marker data"
  local output_file="$STATE_DIR/repo_resume_mysql_marker.out"
  if mysql_query_capture \
    "SELECT COUNT(*) FROM items WHERE name = '$REPO_MYSQL_MARKER';" \
    "$output_file"; then
    local mysql_marker_count
    mysql_marker_count="$(tr -d '\r' <"$output_file" | tail -n 1)"
    if [[ "$mysql_marker_count" == "1" ]]; then
      record_result "repo_resume_mysql_marker" "PASS" "$REPO_MYSQL_MARKER"
    else
      record_result "repo_resume_mysql_marker" "FAIL" "expected 1 got ${mysql_marker_count:-<empty>}"
      print_repo_diagnostics
      print_summary
      exit 1
    fi
  else
    record_result "repo_resume_mysql_marker" "FAIL" "$(summarize_output_file "$output_file")"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Verifying Postgres marker data"
  output_file="$STATE_DIR/repo_resume_postgres_marker.out"
  if postgres_query_capture \
    "SELECT COUNT(*) FROM $REPO_POSTGRES_MARKER_TABLE WHERE marker = '$REPO_POSTGRES_MARKER';" \
    "$output_file"; then
    local postgres_marker_count
    postgres_marker_count="$(tr -d '\r' <"$output_file" | tail -n 1)"
    if [[ "$postgres_marker_count" == "1" ]]; then
      record_result "repo_resume_postgres_marker" "PASS" "$REPO_POSTGRES_MARKER"
    else
      record_result "repo_resume_postgres_marker" "FAIL" "expected 1 got ${postgres_marker_count:-<empty>}"
      print_repo_diagnostics
      print_summary
      exit 1
    fi
  else
    record_result "repo_resume_postgres_marker" "FAIL" "$(summarize_output_file "$output_file")"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  log_step "Posting an item and waiting for worker processing"
  local item_name="repo-resume-$RUN_ID-$(date +%s)"
  if post_item "$item_name"; then
    record_result "repo_resume_item_post" "PASS" "$item_name"
  else
    record_result "repo_resume_item_post" "FAIL" "POST $ITEMS_URL failed"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  local total_after=""
  local processed_after=""
  local pending_after=""
  if read -r total_after processed_after pending_after < <(
    wait_for_expected_stats \
      "$((total_before + 1))" \
      "$((processed_before + 1))" \
      "$STATS_TIMEOUT_SECONDS" \
      true
  ); then
    record_result "repo_resume_roundtrip" "PASS" "total=$total_after processed=$processed_after pending=$pending_after"
  else
    record_result "repo_resume_roundtrip" "FAIL" "stats did not advance"
    print_repo_diagnostics
    print_summary
    exit 1
  fi

  save_state_var "REPO_EXPECTED_TOTAL_ITEMS" "$total_after"
  save_state_var "REPO_EXPECTED_PROCESSED_ITEMS" "$processed_after"
  save_state_var "REPO_EXPECTED_PENDING_JOBS" "$pending_after"

  log
  log "=== Repo Services After Resume ==="
  (
    cd "$APP_DIR"
    docker_compose_cmd ps || true
  )
  print_summary
}

validate_mode() {
  case "$MODE" in
    capabilities|simple-setup|simple-verify|repo-setup|repo-verify|state-get)
      ;;
    *)
      echo "Invalid or missing --mode" >&2
      usage >&2
      exit 1
      ;;
  esac
}

run_state_get_mode() {
  load_state
  if [[ -z "$STATE_KEY" ]]; then
    echo "--state-key is required for state-get mode" >&2
    exit 1
  fi
  printf '%s\n' "${!STATE_KEY:-}"
}

main() {
  parse_args "$@"
  validate_mode
  ensure_common_prerequisites

  case "$MODE" in
    capabilities)
      run_capabilities_mode
      ;;
    simple-setup)
      run_simple_setup_mode
      ;;
    simple-verify)
      run_simple_verify_mode
      ;;
    repo-setup)
      run_repo_setup_mode
      ;;
    repo-verify)
      run_repo_verify_mode
      ;;
    state-get)
      run_state_get_mode
      ;;
  esac
}

main "$@"
