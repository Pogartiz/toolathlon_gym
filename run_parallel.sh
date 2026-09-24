#!/bin/bash
# Fully parallel benchmark: every task gets its own PostgreSQL + agent container.
#
# Usage:
#   ./run_parallel.sh <max_concurrent> [task1 task2 ...]
#
# OUTPUT_ROOT / RUN_ID — attempt directory (exclusive create).
# Results: $OUTPUT_ROOT/$RUN_ID/results.jsonl
#
# Model: MODEL_NAME/MODEL, MODEL_PROVIDER/PROVIDER, MODEL_API_KEY, MODEL_API_URL, MODEL_PLATFORM
# LLM hang bounds: MODEL_TIMEOUT (default 180), MODEL_MAX_RETRIES (default 0 = fail-fast)
# Images: IMAGE, POSTGRES_IMAGE (both inspected before start; no surprise pull)

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MAX_CONCURRENT="${1:?Usage: $0 <max_concurrent> [task1] [task2] ...}"
shift

case "$MAX_CONCURRENT" in
    ''|*[!0-9]*) echo "[error] MAX_CONCURRENT must be a positive integer" >&2; exit 1 ;;
esac
if [ "$MAX_CONCURRENT" -lt 1 ]; then
    echo "[error] MAX_CONCURRENT must be >= 1" >&2
    exit 1
fi

validate_slug() {
    local t="$1"
    if [[ "$t" == .* || "$t" == *"/"* || "$t" == *".."* || -z "$t" ]]; then
        echo "[error] Invalid task slug: $t" >&2
        return 1
    fi
    if [[ ! -d "tasks/finalpool/$t" ]]; then
        echo "[error] Task directory not found: tasks/finalpool/$t" >&2
        return 1
    fi
}

if [ $# -gt 0 ]; then
    TASKS=("$@")
else
    TASKS=()
    while IFS= read -r t; do
        [[ "$t" == .* ]] && continue
        TASKS+=("$t")
    done < <(ls tasks/finalpool/)
fi

for t in "${TASKS[@]}"; do
    validate_slug "$t" || exit 1
done

MODEL="${MODEL_NAME:-${MODEL:-}}"
PROVIDER="${MODEL_PROVIDER:-${PROVIDER:-}}"
if [ -z "$MODEL" ] || [ -z "$PROVIDER" ]; then
    echo "[error] MODEL_NAME/MODEL and MODEL_PROVIDER/PROVIDER are required" >&2
    exit 1
fi
MAX_STEPS="${MAX_STEPS:-100}"
IMAGE="${IMAGE:-toolathlon-pack:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_ROOT="${OUTPUT_ROOT:-$SCRIPT_DIR/benchmark_logs}"
RUN_ID="${RUN_ID:-fully_parallel_${TIMESTAMP}}"
LOG_DIR="$OUTPUT_ROOT/$RUN_ID"
DOCKER=$(which docker 2>/dev/null || echo "/usr/local/bin/docker")

mkdir -p "$OUTPUT_ROOT"
if [ -e "$LOG_DIR" ]; then
    echo "[error] RUN_ID directory already exists: $LOG_DIR (refuse reuse)" >&2
    exit 1
fi
mkdir "$LOG_DIR"
mkdir -p "$LOG_DIR/tasks"

echo "============================================="
echo "Fully Parallel Benchmark"
echo "  Max concurrent: $MAX_CONCURRENT"
echo "  Total tasks:    ${#TASKS[@]}"
echo "  Model:          $PROVIDER/$MODEL"
echo "  Max steps:      $MAX_STEPS"
echo "  Image:          $IMAGE"
echo "  Postgres image: $POSTGRES_IMAGE"
echo "  Log dir:        $LOG_DIR"
echo "============================================="

if ! $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[error] Agent image '$IMAGE' not found." >&2
    exit 1
fi
if ! $DOCKER image inspect "$POSTGRES_IMAGE" >/dev/null 2>&1; then
    echo "[error] Postgres image '$POSTGRES_IMAGE' not found (pull/pin first)." >&2
    exit 1
fi

FIFO="$LOG_DIR/.semaphore"
mkfifo "$FIFO"
exec 3<>"$FIFO"
rm -f "$FIFO"
for ((i = 0; i < MAX_CONCURRENT; i++)); do
    echo >&3
done

SUMMARY="$LOG_DIR/summary.csv"
RESULTS_JSONL="$LOG_DIR/results.jsonl"
: > "$RESULTS_JSONL"
echo "task,status,eval_pass,measured,duration_s" > "$SUMMARY"
SUMMARY_LOCK="$LOG_DIR/.summary.lock"
RESULTS_LOCK="$LOG_DIR/.results.lock"

append_summary() {
    while ! mkdir "$SUMMARY_LOCK" 2>/dev/null; do sleep 0.1; done
    printf '%s\n' "$1" >> "$SUMMARY"
    rmdir "$SUMMARY_LOCK"
}

append_result_jsonl() {
    while ! mkdir "$RESULTS_LOCK" 2>/dev/null; do sleep 0.1; done
    printf '%s\n' "$1" >> "$RESULTS_JSONL"
    rmdir "$RESULTS_LOCK"
}

CONTAINER_LIST="$LOG_DIR/.containers"
NETWORK_LIST="$LOG_DIR/.networks"
touch "$CONTAINER_LIST" "$NETWORK_LIST"
CONTAINER_LIST_LOCK="$LOG_DIR/.containers.lock"
NETWORK_LIST_LOCK="$LOG_DIR/.networks.lock"

register_container() {
    while ! mkdir "$CONTAINER_LIST_LOCK" 2>/dev/null; do sleep 0.1; done
    printf '%s\n' "$1" >> "$CONTAINER_LIST"
    rmdir "$CONTAINER_LIST_LOCK"
}

register_network() {
    while ! mkdir "$NETWORK_LIST_LOCK" 2>/dev/null; do sleep 0.1; done
    printf '%s\n' "$1" >> "$NETWORK_LIST"
    rmdir "$NETWORK_LIST_LOCK"
}

cleanup_all() {
    echo ""
    echo "Cleaning up all containers and networks..."
    if [ -f "$CONTAINER_LIST" ]; then
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            $DOCKER rm -f "$c" >/dev/null 2>&1 || true
        done < "$CONTAINER_LIST"
    fi
    if [ -f "$NETWORK_LIST" ]; then
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            $DOCKER network rm "$n" >/dev/null 2>&1 || true
        done < "$NETWORK_LIST"
    fi
    exec 3>&- 2>/dev/null || true
    echo "Cleanup done."
}
trap cleanup_all EXIT

export MODEL PROVIDER MAX_STEPS IMAGE POSTGRES_IMAGE DOCKER LOG_DIR
export SUMMARY SUMMARY_LOCK CONTAINER_LIST CONTAINER_LIST_LOCK
export NETWORK_LIST NETWORK_LIST_LOCK RESULTS_JSONL RESULTS_LOCK
export GEMINI_API_KEY="${GEMINI_API_KEY:-}"
export MODEL_API_KEY="${MODEL_API_KEY:-}"
export MODEL_PLATFORM="${MODEL_PLATFORM:-}"
export MODEL_API_URL="${MODEL_API_URL:-}"
export MODEL_PROVIDER="$PROVIDER"
export MODEL_NAME="$MODEL"
export -f append_summary append_result_jsonl register_container register_network validate_slug

run_one_task() {
    local TASK="$1"
    validate_slug "$TASK" || return 1

    local TASK_HASH
    TASK_HASH=$(echo "$TASK" | md5 -q 2>/dev/null || echo "$TASK" | md5sum 2>/dev/null | cut -c1-8 || echo "$RANDOM")
    local TASK_ID="$$-${TASK_HASH:0:8}"
    local PG_CONTAINER="pg-${TASK_ID}"
    local AGENT_CONTAINER="agent-${TASK_ID}"
    local TASK_LOG="$LOG_DIR/${TASK}.log"
    local TASK_OUT="$LOG_DIR/tasks/$TASK"
    local NET_NAME="net-${TASK_ID}"
    local META_FILE="$TASK_OUT/lighteval_result.json"
    local START_TS END_TS DURATION

    mkdir -p "$TASK_OUT"
    START_TS=$(date +%s)
    echo "[$(date +%H:%M:%S)] START  $TASK"

    $DOCKER network create "$NET_NAME" >> "$TASK_LOG" 2>&1 || true
    register_network "$NET_NAME"
    register_container "$PG_CONTAINER"
    register_container "$AGENT_CONTAINER"

    $DOCKER run -d \
        --name "$PG_CONTAINER" \
        --network "$NET_NAME" \
        -e POSTGRES_DB=toolathlon_gym \
        -e POSTGRES_USER=eigent \
        -e POSTGRES_PASSWORD=camel \
        -v "$(pwd)/db/init.sql.gz:/docker-entrypoint-initdb.d/init.sql.gz:ro" \
        --health-cmd="pg_isready -U eigent -d toolathlon_gym" \
        --health-interval=3s --health-retries=20 \
        "$POSTGRES_IMAGE" >> "$TASK_LOG" 2>&1

    local RETRIES=60 READY=false ST
    while [ $RETRIES -gt 0 ]; do
        ST=$($DOCKER inspect --format '{{.State.Health.Status}}' "$PG_CONTAINER" 2>/dev/null || echo "missing")
        if [ "$ST" = "healthy" ]; then READY=true; break; fi
        sleep 2
        RETRIES=$((RETRIES - 1))
    done

    if [ "$READY" != "true" ]; then
        echo "[$(date +%H:%M:%S)] FAIL   $TASK (postgres not healthy)" | tee -a "$TASK_LOG"
        END_TS=$(date +%s)
        DURATION=$((END_TS - START_TS))
        python3 - "$TASK" "$TASK_OUT" "$DURATION" "$META_FILE" \
            "$TASK_OUT/.parse_stdout" "$TASK_OUT/.parse_stderr" <<'PY'
import json, os, sys
from pathlib import Path
task, out_dir, duration, meta_file = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4])
stdout_path, stderr_path = Path(sys.argv[5]), Path(sys.argv[6])
payload = {
    "task": task,
    "pass": None,
    "measured": False,
    "failure": "pg_fail",
    "duration_s": duration,
    "eval_res_path": None,
    "output_dir": str(out_dir),
}
tmp = meta_file.with_suffix(".tmp")
tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
os.replace(tmp, meta_file)
stdout_path.write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
stderr_path.write_text(f"{task},infra_fail,null,false,{duration}\n", encoding="utf-8")
PY
        append_result_jsonl "$(cat "$TASK_OUT/.parse_stdout")"
        append_summary "$(cat "$TASK_OUT/.parse_stderr")"
        $DOCKER rm -f "$PG_CONTAINER" >> "$TASK_LOG" 2>&1 || true
        $DOCKER network rm "$NET_NAME" >> "$TASK_LOG" 2>&1 || true
        return 1
    fi

    $DOCKER run --rm --network "$NET_NAME" \
        -e PGHOST="$PG_CONTAINER" -e PGPORT=5432 \
        -e PGDATABASE=toolathlon_gym -e PGUSER=eigent -e PGPASSWORD=camel \
        "$IMAGE" /opt/venv/bin/python3 -c "
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
" >> "$TASK_LOG" 2>&1 || true

    local ENV_ARGS=()
    local HOST_ARGS=()
    local HOST_PINS=""
    [ -n "${GEMINI_API_KEY:-}" ]  && ENV_ARGS+=("-e" "GEMINI_API_KEY=$GEMINI_API_KEY")
    [ -n "${MODEL_API_KEY:-}" ]   && ENV_ARGS+=("-e" "MODEL_API_KEY=$MODEL_API_KEY")
    [ -n "${MODEL_PLATFORM:-}" ]  && ENV_ARGS+=("-e" "MODEL_PLATFORM=$MODEL_PLATFORM")
    [ -n "${MODEL_API_URL:-}" ]   && ENV_ARGS+=("-e" "MODEL_API_URL=$MODEL_API_URL")
    ENV_ARGS+=("-e" "MODEL_PROVIDER=$PROVIDER")
    ENV_ARGS+=("-e" "MODEL_NAME=$MODEL")
    [ -n "${AGENT_STEP_TIMEOUT:-}" ] && ENV_ARGS+=("-e" "AGENT_STEP_TIMEOUT=$AGENT_STEP_TIMEOUT")
    [ -n "${TOOL_EXECUTION_TIMEOUT:-}" ] && ENV_ARGS+=("-e" "TOOL_EXECUTION_TIMEOUT=$TOOL_EXECUTION_TIMEOUT")
    [ -n "${MCP_STDIO_TIMEOUT:-}" ] && ENV_ARGS+=("-e" "MCP_STDIO_TIMEOUT=$MCP_STDIO_TIMEOUT")
    [ -n "${MODEL_TIMEOUT:-}" ] && ENV_ARGS+=("-e" "MODEL_TIMEOUT=$MODEL_TIMEOUT")
    [ -n "${MODEL_MAX_RETRIES:-}" ] && ENV_ARGS+=("-e" "MODEL_MAX_RETRIES=$MODEL_MAX_RETRIES")
    [ -z "${AGENT_STEP_TIMEOUT:-}" ] && ENV_ARGS+=("-e" "AGENT_STEP_TIMEOUT=180")
    [ -z "${TOOL_EXECUTION_TIMEOUT:-}" ] && ENV_ARGS+=("-e" "TOOL_EXECUTION_TIMEOUT=60")
    [ -z "${MCP_STDIO_TIMEOUT:-}" ] && ENV_ARGS+=("-e" "MCP_STDIO_TIMEOUT=60")
    # Fail-fast LLM: one hung completion must not burn retries × timeout.
    [ -z "${MODEL_TIMEOUT:-}" ] && ENV_ARGS+=("-e" "MODEL_TIMEOUT=180")
    [ -z "${MODEL_MAX_RETRIES:-}" ] && ENV_ARGS+=("-e" "MODEL_MAX_RETRIES=0")
    # Offline tiktoken encodings (baked in image; host .tiktoken_cache overrides when present).
    ENV_ARGS+=("-e" "TIKTOKEN_CACHE_DIR=${TIKTOKEN_CACHE_DIR:-/opt/tiktoken_cache}")
    HOST_PINS=$(python3 - "${MODEL_API_URL:-https://openrouter.ai/api/v1}" <<'PY'
import socket, sys
from urllib.parse import urlparse
url = sys.argv[1].strip() or "https://openrouter.ai/api/v1"
hosts = [urlparse(url).hostname or "openrouter.ai", "openaipublic.blob.core.windows.net"]
seen=set()
for host in hosts:
    if host in seen:
        continue
    seen.add(host)
    try:
        ip = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except OSError:
        continue
    print(f"{host}:{ip}")
PY
)
    if [ -n "$HOST_PINS" ]; then
        while IFS= read -r HOST_PIN; do
            [ -z "$HOST_PIN" ] && continue
            HOST_ARGS+=(--add-host "$HOST_PIN")
            echo "[$(date +%H:%M:%S)] Pinning outbound host to IPv4: $HOST_PIN" | tee -a "$TASK_LOG"
        done <<< "$HOST_PINS"
    fi

    local VOL_ARGS=()
    VOL_ARGS+=(-v "$(pwd):/workspace")
    VOL_ARGS+=(-v "$TASK_OUT:/workspace/dumps")
    # Prefer host-prefetched encodings so current images work before rebuild.
    if [ -d "$(pwd)/.tiktoken_cache" ] && [ -n "$(ls -A "$(pwd)/.tiktoken_cache" 2>/dev/null || true)" ]; then
        VOL_ARGS+=(-v "$(pwd)/.tiktoken_cache:/opt/tiktoken_cache:ro")
    fi

    $DOCKER run -d \
        --name "$AGENT_CONTAINER" \
        --network "$NET_NAME" \
        "${HOST_ARGS[@]}" \
        -e PGHOST="$PG_CONTAINER" \
        -e PG_HOST="$PG_CONTAINER" \
        -e PGPORT=5432 \
        -e PGUSER=eigent \
        -e PGPASSWORD=camel \
        -e PGDATABASE=toolathlon_gym \
        -e LOCAL_SERVERS_PATH=/opt/local_servers \
        -e PYTHON_BIN=/opt/venv/bin/python3 \
        "${ENV_ARGS[@]}" \
        "${VOL_ARGS[@]}" \
        -w /workspace \
        "$IMAGE" sleep 7200 >> "$TASK_LOG" 2>&1

    sleep 1

    $DOCKER exec \
        "$AGENT_CONTAINER" \
        /opt/venv/bin/python3 -u /workspace/main.py \
            --provider "$PROVIDER" \
            --model_name "$MODEL" \
            --task_dir "$TASK" \
            --max_steps "$MAX_STEPS" \
        >> "$TASK_LOG" 2>&1 || true

    END_TS=$(date +%s)
    DURATION=$((END_TS - START_TS))

    python3 - "$TASK" "$TASK_OUT" "$DURATION" "$TASK_LOG" "$META_FILE" \
        "$TASK_OUT/.parse_stdout" "$TASK_OUT/.parse_stderr" <<'PY'
import json, os, sys
from pathlib import Path

task, out_dir, duration, task_log, meta_file = (
    sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4]), Path(sys.argv[5])
)
stdout_path, stderr_path = Path(sys.argv[6]), Path(sys.argv[7])
candidates = sorted(out_dir.glob("**/eval_res.json"))
payload = {
    "task": task,
    "duration_s": duration,
    "output_dir": str(out_dir),
    "task_log": str(task_log),
}
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

tmp = meta_file.with_suffix(".tmp")
tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
os.replace(tmp, meta_file)
stdout_path.write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
pass_s = {True: "True", False: "False", None: "null"}.get(payload["pass"], "null")
measured_s = "true" if payload.get("measured") else "false"
status = "success" if payload.get("measured") else "infra_fail"
stderr_path.write_text(f"{task},{status},{pass_s},{measured_s},{duration}\n", encoding="utf-8")
PY

    append_result_jsonl "$(cat "$TASK_OUT/.parse_stdout")"
    append_summary "$(cat "$TASK_OUT/.parse_stderr")"

    local RESULT_LABEL="UNMEASURED"
    if grep -q '"pass": true' "$TASK_OUT/.parse_stdout" 2>/dev/null; then
        RESULT_LABEL="PASS"
    elif grep -q '"measured": true' "$TASK_OUT/.parse_stdout" 2>/dev/null; then
        RESULT_LABEL="EVAL_FAIL"
    fi
    echo "[$(date +%H:%M:%S)] DONE   $TASK -> $RESULT_LABEL (${DURATION}s)"

    $DOCKER rm -f "$AGENT_CONTAINER" >> "$TASK_LOG" 2>&1 || true
    $DOCKER rm -f "$PG_CONTAINER" >> "$TASK_LOG" 2>&1 || true
    $DOCKER network rm "$NET_NAME" >> "$TASK_LOG" 2>&1 || true
}

export -f run_one_task

PIDS=()
for TASK in "${TASKS[@]}"; do
    read -u 3
    (
        run_one_task "$TASK"
        echo >&3
    ) &
    PIDS+=($!)
done

echo ""
echo "All ${#TASKS[@]} tasks launched (max $MAX_CONCURRENT concurrent). Waiting..."
echo ""

for pid in "${PIDS[@]}"; do
    wait "$pid" || true
done

echo ""
echo "============================================="
echo "RESULTS"
echo "============================================="
echo "JSONL: $RESULTS_JSONL"
echo "CSV:   $SUMMARY"
python3 - "$RESULTS_JSONL" <<'PYEOF'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
rows = []
for line in path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if line:
        rows.append(json.loads(line))

pass_count = eval_fail = unmeasured = 0
for row in sorted(rows, key=lambda r: r.get("task", "")):
    task = row.get("task", "?")
    if row.get("pass") is True:
        label, pass_count = "PASS", pass_count + 1
    elif row.get("measured") is True:
        label, eval_fail = "EVAL_FAIL", eval_fail + 1
    else:
        label, unmeasured = "UNMEASURED", unmeasured + 1
    print(f"  {task:<55s} {label:<12s} ({row.get('duration_s', '?')}s)")

total = pass_count + eval_fail + unmeasured
print()
if total:
    print(f"  PASS:       {pass_count:4d}")
    print(f"  EVAL_FAIL:  {eval_fail:4d}")
    print(f"  UNMEASURED: {unmeasured:4d}")
    print(f"  TOTAL:      {total:4d}")
else:
    print("  No results.")
PYEOF

echo ""
echo "Done."
