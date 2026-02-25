#!/usr/bin/env bash
set -euo pipefail

system_prompt=""
read -r -d '' system_prompt <<'EOF' || true
You are a command suggestion assistant for terminal users.

Hard rules:
1) Never execute commands.
2) Never run shell commands.
3) Never read, open, inspect, or list files/directories.
4) Never infer repository or filesystem state beyond the provided context.
5) Only suggest commands for the user to run themselves.

Output contract (strict):
- Return EXACTLY one shell command by default.
- Output plain terminal text only.
- No Markdown, no code fences, no bullets, no tables, no labels.
- No preface or explanation lines.
- Do not output words like "Recommended", "Alternative", "Use", or commentary.
- Put the command on a single line, copy-paste ready.
- Use ASCII only.
- Use normal hyphen-minus ("-") for flags, never en dash/em dash.

When user explicitly asks for alternatives/options/comparison:
- Return one command per line.
- Commands only, no labels or explanations.

Command selection rules:
- Choose the simplest valid command that directly answers the question.
- Prefer portable defaults available on macOS/Linux.
- Prefer pgrep -af NAME over ps ... | grep ... for process lookup when appropriate.
- For recursive text search, prefer rg with minimal valid flags.
- For file-name search, prefer precise find forms (-type f, -name/-iname).
- Quote user-provided literals safely.
- Avoid unnecessary pipelines/subshells when a single command works.
- Avoid destructive commands by default; if mutation is requested, suggest a safe preview/list command first.
- Avoid sudo unless strictly required.

Self-check before final output:
- The command is syntactically valid.
- Flags are valid for the selected tool.
- The command directly matches the user request.
- Output fully follows the strict output contract.
EOF

usage() {
  cat <<'EOF'
Usage: c [--new] [-v|-vv] <question...>

Asks Codex non-interactively and auto-resumes the last conversation when:
- current directory is unchanged, and
- last invocation was within the resume window (default: 300 seconds).

Options:
  --new              Force a new conversation (disable auto-resume once)
  -v, --verbose      Show wrapper diagnostics
  -vv                Show full debug output (stderr + JSON events)
  -m, --model        Model name (default: gpt-5.1-codex-mini)
  -w, --window       Auto-resume window in seconds (default: 300)
  -r, --reasoning-effort  Model reasoning effort (default: low)
  -h, --help         Show this help

Environment:
  C_CONTEXT_ENV_VARS   Space-separated env var names exposed in context.
                       Defaults to: HOME USER SHELL EDITOR VISUAL PAGER LANG TERM
                       Only existing vars are included.
  C_STATE_DIR          (default: ~/.local/state/c)
  C_NO_SPINNER         Set to 1 to disable the interactive loading spinner
EOF
}

if ! command -v codex >/dev/null 2>&1; then
  echo "c: codex CLI not found in PATH" >&2
  exit 127
fi

force_new=0
verbose=0
model="gpt-5.1-codex-mini"
window_seconds="300"
reasoning_effort="low"

note() {
  if (( verbose >= 1 )); then
    printf '%s\n' "$*" >&2
  fi
}

spinner_pid=""
spinner_start() {
  [[ -n "$spinner_pid" ]] && return 0

  local mode_label="$1"
  local model_label="$2"
  local reasoning_label="$3"
  local dim=""
  local reset=""

  if command -v tput >/dev/null 2>&1 && [[ -n "${TERM:-}" && "${TERM}" != "dumb" ]]; then
    dim="$(tput dim 2>/dev/null || true)"
    reset="$(tput sgr0 2>/dev/null || true)"
  fi
  if [[ -z "$dim" || -z "$reset" ]]; then
    dim=$'\033[2m'
    reset=$'\033[0m'
  fi

  (
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    local frame=""
    while :; do
      frame="${frames[i % ${#frames[@]}]}"
      printf '\r\033[2K[c] %s waiting for answer %s(%s, model=%s, reasoning=%s)%s' \
        "$frame" "$dim" "$mode_label" "$model_label" "$reasoning_label" "$reset" >&2
      i=$((i + 1))
      sleep 0.08
    done
  ) &
  spinner_pid="$!"
}

spinner_stop() {
  if [[ -n "$spinner_pid" ]] && kill -0 "$spinner_pid" >/dev/null 2>&1; then
    kill "$spinner_pid" >/dev/null 2>&1 || true
    wait "$spinner_pid" 2>/dev/null || true
  fi
  spinner_pid=""
  if [[ -t 2 ]]; then
    printf '\r\033[2K' >&2
  fi
}

join_by() {
  local sep="$1"
  shift || true
  local out=""
  local first=1
  local item
  for item in "$@"; do
    if (( first )); then
      out="$item"
      first=0
    else
      out+="${sep}${item}"
    fi
  done
  printf '%s' "$out"
}

question_parts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --new)
      force_new=1
      shift
      ;;
    -vv)
      verbose=2
      shift
      ;;
    -v|--verbose)
      (( verbose += 1 ))
      shift
      ;;
    -m|--model)
      [[ $# -lt 2 ]] && { echo "c: missing value for $1" >&2; exit 2; }
      model="$2"
      shift 2
      ;;
    -w|--window)
      [[ $# -lt 2 ]] && { echo "c: missing value for $1" >&2; exit 2; }
      window_seconds="$2"
      shift 2
      ;;
    -r|--reasoning-effort)
      [[ $# -lt 2 ]] && { echo "c: missing value for $1" >&2; exit 2; }
      reasoning_effort="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        question_parts+=("$1")
        shift
      done
      ;;
    -*)
      echo "c: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      question_parts+=("$1")
      shift
      ;;
  esac
done

if [[ ${#question_parts[@]} -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    question_parts+=("$(cat)")
  else
    usage >&2
    exit 1
  fi
fi

question="$(join_by ' ' "${question_parts[@]}")"
if ! [[ "$window_seconds" =~ ^[0-9]+$ ]]; then
  echo "c: --window must be a positive integer" >&2
  exit 2
fi
if (( window_seconds <= 0 )); then
  echo "c: --window must be greater than zero" >&2
  exit 2
fi

detected_shells=()
for shell_name in zsh bash fish; do
  if command -v "$shell_name" >/dev/null 2>&1; then
    detected_shells+=("$shell_name")
  fi
done
if [[ ${#detected_shells[@]} -eq 0 ]]; then
  detected_shells=("unknown")
fi
available_shells="$(join_by ', ' "${detected_shells[@]}")"

context_env_names="${C_CONTEXT_ENV_VARS:-HOME USER SHELL EDITOR VISUAL PAGER LANG TERM}"
context_env_block=""
env_name_array=()
IFS=' ' read -r -a env_name_array <<< "$context_env_names"
for name in "${env_name_array[@]}"; do
  [[ -z "$name" ]] && continue
  # Only allow simple variable names to prevent prompt injection via names.
  if ! [[ "$name" == [A-Za-z_][A-Za-z0-9_]* ]]; then
    continue
  fi
  value="${!name-}"
  if [[ -n "$value" ]]; then
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    context_env_block+="- ${name}=${value}\n"
  fi
done
if [[ -z "$context_env_block" ]]; then
  context_env_block="- (none)\n"
fi

state_dir="${C_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/c}"
mkdir -p "$state_dir"
last_cwd_file="$state_dir/last_cwd"
last_time_file="$state_dir/last_invoked_at"
last_thread_file="$state_dir/last_thread_id"

now="$(date +%s)"
can_resume=0
last_thread_id=""
if [[ "$force_new" -eq 0 && -r "$last_cwd_file" && -r "$last_time_file" && -r "$last_thread_file" ]]; then
  last_cwd="$(<"$last_cwd_file")"
  last_time_raw="$(<"$last_time_file")"
  last_thread_id="$(<"$last_thread_file")"

  if [[ "$last_time_raw" =~ ^[0-9]+$ ]]; then
    age=$(( now - last_time_raw ))
    if [[ "$last_cwd" == "$PWD" && $age -ge 0 && $age -lt $window_seconds && -n "$last_thread_id" ]]; then
      can_resume=1
    fi
  fi
fi

initial_payload=$(
  cat <<EOF
$system_prompt

Context:
- available_shells: $available_shells
- environment variables:
$(printf "%b" "$context_env_block")

User question:
$question
EOF
)
resume_payload="$question"

log_file="$(mktemp "${TMPDIR:-/tmp}/c-log.XXXXXX")"
json_log="$(mktemp "${TMPDIR:-/tmp}/c-json.XXXXXX")"
err_log="$(mktemp "${TMPDIR:-/tmp}/c-err.XXXXXX")"
cleanup() {
  spinner_stop
  rm -f "$log_file"
  rm -f "$json_log"
  rm -f "$err_log"
}
trap cleanup EXIT

request_mode="new thread"
if [[ "$can_resume" -eq 1 ]]; then
  request_mode="follow-up"
fi

use_spinner=0
if [[ -t 2 && "${C_NO_SPINNER:-0}" != "1" && "$verbose" -lt 2 ]]; then
  use_spinner=1
fi

if [[ "$can_resume" -eq 1 ]]; then
  note "[c] mode=resume thread=$last_thread_id window=${window_seconds}s"
  cmd=(
    codex exec resume
    --skip-git-repo-check
    --json
    -m "$model"
    -c "model_reasoning_effort=\"$reasoning_effort\""
    "$last_thread_id"
    "$resume_payload"
  )
else
  note "[c] mode=new window=${window_seconds}s"
  cmd=(
    codex exec
    --skip-git-repo-check
    --json
    --sandbox read-only
    -m "$model"
    -c "model_reasoning_effort=\"$reasoning_effort\""
    "$initial_payload"
  )
fi

if [[ "$use_spinner" -eq 1 ]]; then
  "${cmd[@]}" >"$json_log" 2>"$err_log" &
  cmd_pid="$!"
  spinner_start "$request_mode" "$model" "$reasoning_effort"
  if wait "$cmd_pid"; then
    exit_code=0
  else
    exit_code=$?
  fi
  spinner_stop
else
  if "${cmd[@]}" >"$json_log" 2>"$err_log"; then
    exit_code=0
  else
    exit_code=$?
  fi
fi

if [[ -s "$json_log" ]]; then
  grep -E '^[[:space:]]*\{' "$json_log" >"$log_file" || true
fi

if [[ "$exit_code" -ne 0 ]]; then
  [[ -s "$err_log" ]] && cat "$err_log" >&2
  if (( verbose >= 1 )) && [[ -s "$json_log" ]]; then
    cat "$json_log" >&2
  fi
  if (( verbose < 2 )); then
    echo "c: request failed (re-run with -vv for diagnostics)" >&2
  fi
  exit "$exit_code"
fi

turn_failed_message=""
if command -v jq >/dev/null 2>&1 && [[ -s "$log_file" ]]; then
  turn_failed_message="$(
    jq -rs -r '
      ([ .[] | select(.type=="turn.failed") | .error.message? ] | last) //
      empty
    ' "$log_file" 2>/dev/null || true
  )"
fi
if [[ -n "$turn_failed_message" ]]; then
  echo "c: codex turn failed: $turn_failed_message" >&2
  if (( verbose < 2 )); then
    echo "c: re-run with -vv for diagnostics" >&2
  fi
  exit 1
fi

assistant_text=""
if command -v jq >/dev/null 2>&1 && [[ -s "$log_file" ]]; then
  assistant_text="$(
    jq -rs -r '
      def assistant_text:
        if .type == "event_msg" and .payload.type? == "agent_message" then
          .payload.message
        elif .type == "response_item" and .payload.type? == "message" and .payload.role? == "assistant" then
          ([.payload.content[]? | select(.type=="output_text") | .text] | join(""))
        elif .type == "message" and .role? == "assistant" then
          ([.content[]? | select(.type=="output_text") | .text] | join(""))
        elif .type == "response_item" and .payload.type? == "output_text" then
          .payload.text
        elif .type == "output_text" then
          .text
        elif .type == "assistant_message" then
          (.message // .text // empty)
        elif .type == "item.completed" and .item.type? == "agent_message" then
          (.item.text // .item.message // empty)
        else
          empty
        end;
      ([ .[] | assistant_text | select(type=="string" and length>0) ] | last) // empty
    ' "$log_file" 2>/dev/null || true
  )"
fi

if [[ -n "$assistant_text" ]]; then
  printf '%s\n' "$assistant_text"
else
  if (( verbose >= 1 )); then
    note "[c] no assistant text found in JSON output"
    [[ -s "$json_log" ]] && cat "$json_log" >&2
  fi
  echo "c: no assistant text in response (re-run with -vv for diagnostics)" >&2
  exit 1
fi

if (( verbose >= 2 )); then
  [[ -s "$err_log" ]] && {
    note "[c] codex stderr:"
    cat "$err_log" >&2
  }
  [[ -s "$json_log" ]] && {
    note "[c] codex json events:"
    cat "$json_log" >&2
  }
fi

if [[ "$exit_code" -eq 0 ]]; then
  new_thread_id=""
  if command -v jq >/dev/null 2>&1 && [[ -s "$log_file" ]]; then
    new_thread_id="$(
      jq -rs -r '
        ([ .[] | select(.type=="thread.started") | .thread_id ] | last) //
        ([ .[] | .thread_id? | select(type=="string" and length>0) ] | last) //
        empty
      ' "$log_file" 2>/dev/null || true
    )"
  fi
  if [[ -z "$new_thread_id" && "$can_resume" -eq 1 ]]; then
    new_thread_id="$last_thread_id"
  fi
  if [[ -n "$new_thread_id" ]]; then
    now="$(date +%s)"
    printf '%s\n' "$PWD" > "$last_cwd_file"
    printf '%s\n' "$now" > "$last_time_file"
    printf '%s\n' "$new_thread_id" > "$last_thread_file"
  fi
fi

exit "$exit_code"
