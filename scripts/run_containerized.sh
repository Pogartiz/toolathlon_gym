#!/bin/bash
# Run a single task in an ephemeral container with per-task filesystem isolation.
#
# Isolation strategy:
#   - Fresh Docker container per task (destroyed on exit).
#   - Shared Postgres (toolathlon_pg); tasks must run sequentially.
#   - Global lock under $PROJECT_ROOT/dumps (independent of OUTPUT_ROOT/RUN_ID).
#
# Prerequisites:
#   1. Build the image:    docker build -t toolathlon-pack:latest .
#   2. Start postgres:     POSTGRES_IMAGE=sha256:… docker compose up -d postgres
#
# Usage:
#   bash scripts/run_containerized.sh <task_name> [max_steps] [image]
#
# Output:
#   OUTPUT_ROOT  Host root (default: <repo>/dumps)
#   RUN_ID       Attempt id (default: timestamp). Directory must not already exist.
#   Result path: $OUTPUT_ROOT/$RUN_ID/<task>/  (+ lighteval_result.json)
#
# Model env: MODEL_PROVIDER, MODEL_NAME, MODEL_API_KEY, MODEL_API_URL, MODEL_PLATFORM
# Postgres pin: optional EXPECTED_POSTGRES_IMAGE (full image ID) must match toolathlon_pg

set -euo pipefail

TASK="${1:?Usage: $0 <task_name> [max_steps] [image]}"
MAX_STEPS="${2:-100}"
IMAGE="${3:-toolathlon-pack:latest}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Validate slug: no slash, no .., not hidden
if [[ "$TASK" == .* || "$TASK" == *"/"* || "$TASK" == *".."* ]]; then
    echo "[error] Invalid task slug: $TASK" >&2
    exit 1
fi
TASK_SOURCE="$PROJECT_ROOT/tasks/finalpool/$TASK"
if [[ ! -d "$TASK_SOURCE" ]]; then
    echo "[error] Task directory not found: $TASK_SOURCE" >&2
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SAFE_TASK="$(echo "$TASK" | tr '/' '-')"
CONTAINER_NAME="toolathlon-${SAFE_TASK}-${TIMESTAMP}"

OUTPUT_ROOT="${OUTPUT_ROOT:-$PROJECT_ROOT/dumps}"
RUN_ID="${RUN_ID:-$TIMESTAMP}"
RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
OUTPUT_DIR="$RUN_DIR/$TASK"

# Per-task exclusive output (same RUN_ID may hold many tasks in one lighteval run).
mkdir -p "$OUTPUT_ROOT"
mkdir -p "$RUN_DIR"
if [[ -e "$OUTPUT_DIR" ]]; then
    echo "[error] Task output already exists: $OUTPUT_DIR (refuse reuse)" >&2
    exit 1
fi
mkdir "$OUTPUT_DIR"

# Global lock (shared Postgres) — NOT under RUN_ID.
LOCK_BASE="$PROJECT_ROOT/dumps"
mkdir -p "$LOCK_BASE"
LOCK_FILE="$LOCK_BASE/.run.lock"
LOCK_DIR="$LOCK_BASE/.run.lock.d"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] [warn] $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] [error] $*" >&2; exit 1; }

# Docker Desktop + custom bridge often has broken IPv6; CAMEL/httpx then stalls in
# getaddrinfo/Happy Eyeballs. Pin outbound API hosts to host-resolved IPv4 via --add-host.
# Do NOT override --dns: replacing Docker Embedded DNS breaks other host lookups
# (e.g. tiktoken → openaipublic.blob.core.windows.net).
resolve_model_api_ipv4_hosts() {
    local url="${MODEL_API_URL:-https://openrouter.ai/api/v1}"
    python3 - "$url" <<'PY'
import socket
import sys
from urllib.parse import urlparse

url = sys.argv[1].strip() or "https://openrouter.ai/api/v1"
hosts = []
primary = urlparse(url).hostname or "openrouter.ai"
hosts.append(primary)
# tiktoken downloads encodings from this host during first model call.
for extra in ("openaipublic.blob.core.windows.net",):
    if extra not in hosts:
        hosts.append(extra)
for host in hosts:
    try:
        ip = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except OSError as exc:
        print(f"[warn] IPv4 resolve failed for {host}: {exc}", file=sys.stderr)
        continue
    print(f"{host}:{ip}")
PY
}

cleanup() {
    log "Cleaning up container $CONTAINER_NAME ..."
    docker stop  "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm    "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

check_prerequisites() {
    command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        die "Image '$IMAGE' not found. Build it first: docker build -t $IMAGE ."
    fi
    if ! docker network inspect toolathlon_net >/dev/null 2>&1; then
        die "Network 'toolathlon_net' not found. Run: docker compose up -d postgres"
    fi
    local pg_status
    pg_status="$(docker inspect --format '{{.State.Health.Status}}' toolathlon_pg 2>/dev/null || echo "missing")"
    if [[ "$pg_status" != "healthy" ]]; then
        die "toolathlon_pg is not healthy (status: $pg_status). Run: docker compose up -d postgres"
    fi
    if [[ -n "${EXPECTED_POSTGRES_IMAGE:-}" ]]; then
        local actual
        actual="$(docker inspect --format '{{.Image}}' toolathlon_pg 2>/dev/null || true)"
        if [[ "$actual" != "$EXPECTED_POSTGRES_IMAGE" ]]; then
            die "toolathlon_pg image mismatch: got '$actual', expected '$EXPECTED_POSTGRES_IMAGE'"
        fi
    fi
}

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock --nonblock 9 2>/dev/null; then
            warn "Another task is already running (lock: $LOCK_FILE). Waiting ..."
            flock 9
        fi
    else
        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
            warn "Another task is already running (lock: $LOCK_DIR). Waiting 3s ..."
            sleep 3
        done
        trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; cleanup' EXIT
    fi
    log "Lock acquired."
}

start_container() {
    log "Starting container $CONTAINER_NAME ..."
    local env_args=()
    local host_args=()
    local host_pins=""
    for var in MODEL_PROVIDER MODEL_PLATFORM MODEL_NAME MODEL_API_KEY MODEL_API_URL \
               AGENT_STEP_TIMEOUT TOOL_EXECUTION_TIMEOUT MCP_STDIO_TIMEOUT MCP_HTTP_TIMEOUT \
               MODEL_TIMEOUT MODEL_MAX_RETRIES; do
        [[ -n "${!var:-}" ]] && env_args+=("-e" "${var}=${!var}")
    done
    # Defaults for exploratory smoke: fail fast on hung LLM / broken MCP.
    [[ -z "${AGENT_STEP_TIMEOUT:-}" ]] && env_args+=("-e" "AGENT_STEP_TIMEOUT=180")
    [[ -z "${TOOL_EXECUTION_TIMEOUT:-}" ]] && env_args+=("-e" "TOOL_EXECUTION_TIMEOUT=60")
    [[ -z "${MCP_STDIO_TIMEOUT:-}" ]] && env_args+=("-e" "MCP_STDIO_TIMEOUT=60")
    [[ -z "${MODEL_TIMEOUT:-}" ]] && env_args+=("-e" "MODEL_TIMEOUT=180")
    [[ -z "${MODEL_MAX_RETRIES:-}" ]] && env_args+=("-e" "MODEL_MAX_RETRIES=0")
    env_args+=("-e" "TIKTOKEN_CACHE_DIR=${TIKTOKEN_CACHE_DIR:-/opt/tiktoken_cache}")
    host_pins="$(resolve_model_api_ipv4_hosts || true)"
    if [[ -n "$host_pins" ]]; then
        while IFS= read -r host_pin; do
            [[ -z "$host_pin" ]] && continue
            host_args+=(--add-host "$host_pin")
            log "Pinning outbound host to IPv4: $host_pin"
            echo "$host_pin" >> "$OUTPUT_DIR/net_pins.txt" || true
        done <<< "$host_pins"
    else
        warn "Could not pin outbound hosts to IPv4; DNS may stall on broken IPv6"
        echo "WARN: no IPv4 pins" > "$OUTPUT_DIR/net_pins.txt" || true
    fi
    # Bash 3.2 + set -u: empty arrays need a safe expansion.
    local vol_args=()
    vol_args+=(-v "$OUTPUT_DIR:/workspace/dumps")
    vol_args+=(-v "$PROJECT_ROOT/utils:/workspace/utils:ro")
    if [[ -d "$PROJECT_ROOT/.tiktoken_cache" ]] && [[ -n "$(ls -A "$PROJECT_ROOT/.tiktoken_cache" 2>/dev/null || true)" ]]; then
        vol_args+=(-v "$PROJECT_ROOT/.tiktoken_cache:/opt/tiktoken_cache:ro")
    fi
    docker run -d \
        --name "$CONTAINER_NAME" \
        --network toolathlon_net \
        ${host_args[@]+"${host_args[@]}"} \
        -e PGHOST=toolathlon_pg \
        -e PG_HOST=toolathlon_pg \
        -e PGPORT=5432 \
        -e PGUSER=eigent \
        -e PGPASSWORD=camel \
        -e PGDATABASE=toolathlon_gym \
        -e LOCAL_SERVERS_PATH=/opt/local_servers \
        -e PYTHON_BIN=/opt/venv/bin/python3 \
        "${env_args[@]}" \
        ${vol_args[@]+"${vol_args[@]}"} \
        -w /workspace \
        "$IMAGE" \
        sleep 3600 \
        >/dev/null
}

wait_for_container() {
    local max_wait=30 count=0
    while (( count < max_wait )); do
        if docker exec "$CONTAINER_NAME" true >/dev/null 2>&1; then
            return 0
        fi
        (( count++ )) || true
        sleep 1
    done
    die "Container did not become ready within ${max_wait}s"
}

run_task() {
    log "Running task: $TASK (max_steps=$MAX_STEPS) ..."
    docker exec "$CONTAINER_NAME" \
        /opt/venv/bin/python3 -c "
import psycopg2, os
conn = psycopg2.connect(host=os.environ['PGHOST'], database=os.environ['PGDATABASE'],
                        user=os.environ['PGUSER'], password=os.environ['PGPASSWORD'])
conn.autocommit = True
cur = conn.cursor()
try:
    cur.execute('ALTER TABLE email.sent_log DROP CONSTRAINT sent_log_message_id_fkey')
    cur.execute('ALTER TABLE email.sent_log ADD CONSTRAINT sent_log_message_id_fkey FOREIGN KEY (message_id) REFERENCES email.messages(id) ON DELETE CASCADE')
except Exception:
    pass
conn.close()
" 2>/dev/null || true

    docker exec "$CONTAINER_NAME" \
        /opt/venv/bin/python3 main.py \
            --task_dir  "$TASK" \
            --max_steps "$MAX_STEPS" \
            --debug \
        2>&1 | tee "$OUTPUT_DIR/run.log"
}

write_result_pointer() {
    python3 - "$OUTPUT_DIR" "$TASK" <<'PY'
import json, os, sys
from pathlib import Path

out_dir = Path(sys.argv[1])
task = sys.argv[2]
candidates = sorted(out_dir.glob("**/eval_res.json"))
payload = {"task": task, "output_dir": str(out_dir)}
if len(candidates) == 0:
    payload.update({"pass": None, "measured": False, "failure": "eval_res_missing", "eval_res_path": None})
elif len(candidates) > 1:
    payload.update({
        "pass": None,
        "measured": False,
        "failure": "ambiguous_eval_res",
        "eval_res_path": [str(p) for p in candidates],
    })
else:
    eval_path = candidates[0]
    payload["eval_res_path"] = str(eval_path)
    try:
        data = json.loads(eval_path.read_text(encoding="utf-8"))
        payload["pass"] = data.get("pass")
        payload["measured"] = data.get("measured", data.get("pass") is not None)
        if "failure" in data:
            payload["failure"] = data.get("failure")
        traj_path = eval_path.parent / "traj.json"
        if traj_path.is_file():
            trajectory = json.loads(traj_path.read_text(encoding="utf-8"))
            messages = trajectory.get("messages", [])
            model_calls = sum(
                1 for message in messages
                if isinstance(message, dict) and message.get("role") == "assistant"
            )
            if model_calls > 0:
                payload["model_calls"] = model_calls
    except Exception as exc:
        payload.update({"pass": None, "measured": False, "failure": f"eval_res_parse_error:{type(exc).__name__}"})

tmp = out_dir / "lighteval_result.json.tmp"
final = out_dir / "lighteval_result.json"
tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
os.replace(tmp, final)
print(f"[result] wrote {final}")
PY
}

log "=============================================="
log "  Task:      $TASK"
log "  Max steps: $MAX_STEPS"
log "  Image:     $IMAGE"
log "  Model:     ${MODEL_NAME:-<from eval_config>} (${MODEL_PROVIDER:-<from eval_config>})"
log "  Output:    $OUTPUT_DIR"
log "=============================================="

check_prerequisites
acquire_lock
start_container
wait_for_container

run_rc=0
run_task || run_rc=$?
write_result_pointer
log "Done. Results written to: $OUTPUT_DIR (exit=$run_rc)"
exit "$run_rc"
