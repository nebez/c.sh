#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -x "$ROOT_DIR/c.sh" ]]; then
  SCRIPT_PATH="$ROOT_DIR/c.sh"
else
  SCRIPT_PATH="$ROOT_DIR/c"
fi
DATA_DIR="$ROOT_DIR/tests/data"

if [[ ! -x "$SCRIPT_PATH" ]]; then
  echo "FAIL: script not executable: $SCRIPT_PATH" >&2
  exit 1
fi

if [[ ! -d "$DATA_DIR" ]]; then
  echo "FAIL: missing data dir: $DATA_DIR" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/c-smoke.XXXXXX")"
cleanup() {
  chmod 644 "$DATA_DIR"/random_*.txt "$DATA_DIR"/sentinel.txt 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

MOCK_BIN="$TMP_ROOT/bin"
MOCK_PAYLOAD_DIR="$TMP_ROOT/payloads"
MOCK_LOG="$TMP_ROOT/mock.log"
MOCK_COUNT_FILE="$TMP_ROOT/call_count"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$MOCK_BIN" "$MOCK_PAYLOAD_DIR" "$STATE_DIR" "$TMP_ROOT/other-dir"

cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_COUNT_FILE:?}"
: "${MOCK_PAYLOAD_DIR:?}"
: "${MOCK_LOG:?}"

count=0
[[ -r "$MOCK_COUNT_FILE" ]] && count="$(<"$MOCK_COUNT_FILE")"
count=$(( count + 1 ))
printf '%s\n' "$count" > "$MOCK_COUNT_FILE"

args_file="$MOCK_PAYLOAD_DIR/args.${count}.txt"
payload_file="$MOCK_PAYLOAD_DIR/payload.${count}.txt"
printf '%s\n' "$@" > "$args_file"

if [[ "${1:-}" != "exec" ]]; then
  echo "mock codex: expected first arg to be exec" >&2
  exit 64
fi
shift

mode="exec"
if [[ "${1:-}" == "resume" ]]; then
  mode="resume"
  shift
fi

positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-git-repo-check|--json)
      shift
      ;;
    --sandbox|-m|-c|-C|-p|--local-provider|--color)
      [[ $# -lt 2 ]] && exit 65
      shift 2
      ;;
    --*)
      shift
      ;;
    -*)
      shift
      ;;
    *)
      positionals+=("$1")
      shift
      ;;
  esac
done

thread_id=""
payload=""
if [[ "$mode" == "resume" ]]; then
  thread_id="${positionals[0]-}"
  payload="${positionals[1]-}"
else
  payload="${positionals[0]-}"
fi

printf '%s\n' "$payload" > "$payload_file"
printf '%s\n' "call=$count mode=$mode thread=$thread_id" >> "$MOCK_LOG"

if [[ "$mode" == "resume" && -n "$thread_id" ]]; then
  tid="$thread_id"
else
  tid="$(printf '11111111-1111-1111-1111-%012d' "$count")"
fi

cat <<JSON
{"type":"thread.started","thread_id":"$tid"}
{"type":"item.completed","item":{"id":"item_$count","type":"agent_message","text":"Mock answer $count"}}
{"type":"turn.completed","usage":{"input_tokens":123,"output_tokens":45}}
JSON
EOF

chmod +x "$MOCK_BIN/codex"

export MOCK_COUNT_FILE MOCK_PAYLOAD_DIR MOCK_LOG

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "expected '$text' in $file"
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "did not expect '$text' in $file"
  fi
}

run_c() {
  PATH="$MOCK_BIN:$PATH" C_STATE_DIR="$STATE_DIR" "$SCRIPT_PATH" "$@"
}

sentinel="$(<"$DATA_DIR/sentinel.txt")"
chmod 000 "$DATA_DIR"/random_*.txt "$DATA_DIR"/sentinel.txt

out1="$(run_c "Suggest a backup strategy")"
[[ "$out1" == "Mock answer 1" ]] || fail "default output should be concise assistant text"
assert_contains "$MOCK_PAYLOAD_DIR/args.1.txt" "--json"
assert_contains "$MOCK_PAYLOAD_DIR/args.1.txt" "--sandbox"
assert_contains "$MOCK_PAYLOAD_DIR/args.1.txt" "read-only"
assert_contains "$MOCK_PAYLOAD_DIR/payload.1.txt" "Never read, open, inspect, or list files/directories."
assert_contains "$MOCK_PAYLOAD_DIR/payload.1.txt" "Give ONE best command by default."
assert_not_contains "$MOCK_PAYLOAD_DIR/payload.1.txt" "$sentinel"

first_thread="$(<"$STATE_DIR/last_thread_id")"

out2="$(run_c "That was not enough detail, try again")"
[[ "$out2" == "Mock answer 2" ]] || fail "second call should return assistant text"
assert_contains "$MOCK_LOG" "call=2 mode=resume thread=$first_thread"
assert_not_contains "$MOCK_PAYLOAD_DIR/args.2.txt" "--sandbox"
assert_contains "$MOCK_PAYLOAD_DIR/payload.2.txt" "That was not enough detail, try again"
assert_not_contains "$MOCK_PAYLOAD_DIR/payload.2.txt" "Never read, open, inspect, or list files/directories."

out3="$(
  cd "$TMP_ROOT/other-dir" && \
    PATH="$MOCK_BIN:$PATH" C_STATE_DIR="$STATE_DIR" "$SCRIPT_PATH" "Different directory question"
)"
[[ "$out3" == "Mock answer 3" ]] || fail "third call should return assistant text"
assert_contains "$MOCK_LOG" "call=3 mode=exec thread="

verbose_stderr="$TMP_ROOT/v1.stderr"
out4="$(
  cd "$TMP_ROOT/other-dir" && \
    PATH="$MOCK_BIN:$PATH" C_STATE_DIR="$STATE_DIR" "$SCRIPT_PATH" -v "Verbose run check" 2>"$verbose_stderr"
)"
[[ "$out4" == "Mock answer 4" ]] || fail "verbose run should still print assistant text"
assert_contains "$verbose_stderr" "[c] mode=resume"

debug_stderr="$TMP_ROOT/v2.stderr"
out5="$(
  cd "$TMP_ROOT/other-dir" && \
    PATH="$MOCK_BIN:$PATH" C_STATE_DIR="$STATE_DIR" "$SCRIPT_PATH" -vv "Debug run check" 2>"$debug_stderr"
)"
[[ "$out5" == "Mock answer 5" ]] || fail "debug run should still print assistant text"
assert_contains "$debug_stderr" "[c] codex json events:"

echo "PASS: smoke tests completed"
