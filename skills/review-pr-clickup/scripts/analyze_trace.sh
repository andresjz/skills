#!/usr/bin/env bash
# analyze_trace.sh — analyze raw conversation trace from claude code --debug
#
# Reads a JSONL trace (one JSON object per line, types: assistant/user/result)
# and produces a structured human-readable summary for debugging runs.
#
# Usage:
#   analyze_trace.sh --input FILE    analyze a saved trace file
#   analyze_trace.sh --pipe          read from stdin
#   analyze_trace.sh --help          show help
#
# Input format (from claude code --debug output):
#   {"type":"assistant","message":{"id":"...","role":"assistant","content":[...],"model":"...","stop_reason":null,...},"session_id":"...","uuid":"..."}
#   {"type":"user","message":{"role":"user","content":[{"tool_use_id":"...","type":"tool_result","content":"...","is_error":false}]},"session_id":"...","uuid":"...","timestamp":"...","tool_use_result":{...}}
#   {"type":"result","subtype":"error_max_turns","duration_ms":...,"total_cost_usd":...,"num_turns":...,"stop_reason":"...","session_id":"...","errors":[...]}

set -uo pipefail

SCRIPT_NAME="${0##*/}"
DEFAULT_WIDTH=72

# --- helpers ----------------------------------------------------------------

die() { echo "[FATAL] $*" >&2; exit 1; }
usage() {
  cat <<USAGE
analyze_trace.sh — analyze raw conversation trace from claude code --debug

Usage:
  $SCRIPT_NAME --input FILE    analyze a saved trace file
  $SCRIPT_NAME --pipe           read from stdin
  $SCRIPT_NAME --help           show this help

Output: structured plain-text summary to stdout.
USAGE
}

hr() {
  local w="${1:-$DEFAULT_WIDTH}"
  printf '%*s\n' "$w" '' | tr ' ' '='
}

# --- classification of tool calls into steps --------------------------------

classify_call() {
  local tool_name="$1" cmd_line="$2"
  local lcmd
  lcmd=$(echo "$cmd_line" | tr '[:upper:]' '[:lower:]')

  case "$tool_name" in
    bash|Bash)
      if echo "$lcmd" | grep -qE 'gh pr (view|diff)'; then
        echo "fetch_pr"
      elif echo "$lcmd" | grep -qE 'gh pr comment'; then
        echo "post_summary"
      elif echo "$lcmd" | grep -qE 'gh api.*pulls/.*/comments'; then
        echo "post_inline"
      elif echo "$lcmd" | grep -qE 'gh api'; then
        echo "gh_api"
      elif echo "$lcmd" | grep -qE 'clickup-cli'; then
        echo "clickup"
      elif echo "$lcmd" | grep -qE 'prefetch\.sh'; then
        echo "prefetch"
      elif echo "$lcmd" | grep -qE 'post_review\.sh'; then
        echo "post_review"
      elif echo "$lcmd" | grep -qE 'grep.*-n'; then
        echo "grep_resolve"
      elif echo "$lcmd" | grep -qE 'cat.*findings\.jsonl|cat >.*summary\.md'; then
        echo "write_file"
      elif echo "$lcmd" | grep -qE 'for f in .*WORKDIR|cleanup'; then
        echo "cleanup"
      elif echo "$lcmd" | grep -qE 'jq'; then
        echo "json_construction"
      elif echo "$lcmd" | grep -qE 'source |export '; then
        echo "env_setup"
      else
        echo "bash_misc"
      fi
      ;;
    Read)
      echo "read_file"
      ;;
    Write)
      echo "write_file"
      ;;
    Glob)
      echo "glob_search"
      ;;
    Grep)
      echo "grep_search"
      ;;
    Edit)
      echo "edit_file"
      ;;
    web_search|WebSearch)
      echo "web_search"
      ;;
    web_fetch|WebFetch)
      echo "web_fetch"
      ;;
    *)
      echo "other"
      ;;
  esac
}

step_label() {
  local classification="$1"
  case "$classification" in
    fetch_pr|prefetch)            echo "prefetch/gh fetch" ;;
    clickup)                      echo "clickup fetch" ;;
    read_file|glob_search|grep_search) echo "code exploration" ;;
    post_summary)                 echo "post summary" ;;
    post_inline|post_review)      echo "post inline" ;;
    cleanup)                      echo "cleanup" ;;
    grep_resolve)                 echo "line resolution" ;;
    json_construction)            echo "json construction" ;;
    write_file)                   echo "write findings" ;;
    edit_file)                    echo "edit file" ;;
    env_setup)                    echo "env setup" ;;
    web_search)                   echo "web search" ;;
    web_fetch)                    echo "web fetch" ;;
    bash_misc)                    echo "bash misc" ;;
    gh_api)                       echo "gh api (other)" ;;
    other)                        echo "other" ;;
    *)                            echo "unknown" ;;
  esac
}

# --- parse and analyze ------------------------------------------------------

INPUT_FILE=""
READ_STDIN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --input) INPUT_FILE="$2"; shift 2 ;;
    --pipe)  READ_STDIN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

if [ -z "$INPUT_FILE" ] && [ "$READ_STDIN" = false ]; then
  die "Specify --input FILE or --pipe. Use --help for usage."
fi

if [ -n "$INPUT_FILE" ]; then
  [ -f "$INPUT_FILE" ] || die "File not found: $INPUT_FILE"
fi

# Read all JSON lines into a temp file for processing
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

if [ -n "$INPUT_FILE" ]; then
  cat "$INPUT_FILE" > "$TMPFILE"
else
  cat > "$TMPFILE"
fi

# Filter valid JSON lines
VALID_LINES=$(mktemp)
trap 'rm -f "$VALID_LINES"' EXIT

grep -E '^\{"type":"(assistant|user|result)"' "$TMPFILE" > "$VALID_LINES" 2>/dev/null || true
LINE_COUNT=$(wc -l < "$VALID_LINES" 2>/dev/null || echo 0)
if [ "$LINE_COUNT" -eq 0 ]; then
  echo "No valid JSON trace lines found (types: assistant/user/result)."
  echo "Make sure the input is raw output from claude code --debug."
  exit 1
fi

# Detect sessions
readarray -t SESSION_IDS < <(jq -r 'select(.session_id != null) | .session_id // empty' "$VALID_LINES" 2>/dev/null | sort -u)
SESSION_COUNT=${#SESSION_IDS[@]}
if [ "$SESSION_COUNT" -eq 0 ]; then
  echo "No session_id found in trace — using 'unknown'"
  SESSION_IDS=("unknown")
  SESSION_COUNT=1
fi

# --- analyze each session ---------------------------------------------------

for sid in "${SESSION_IDS[@]}"; do
  # Filter lines for this session
  if [ "$SESSION_COUNT" -gt 1 ]; then
    # Multiple sessions — need to filter per session
    SESSION_LINES=$(mktemp)
    trap 'rm -f "$SESSION_LINES"' EXIT
    if [ "$sid" = "unknown" ]; then
      jq -r 'select(.session_id == null or .session_id == "")' "$VALID_LINES" 2>/dev/null > "$SESSION_LINES"
    else
      jq -r --arg sid "$sid" 'select(.session_id == $sid)' "$VALID_LINES" 2>/dev/null > "$SESSION_LINES"
    fi
  else
    SESSION_LINES="$VALID_LINES"
  fi

  echo ""
  hr
  if [ "$SESSION_COUNT" -gt 1 ]; then
    echo " Session: $sid"
    hr
  fi

  # Extract model name from first assistant message
  MODEL=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$SESSION_LINES" 2>/dev/null | head -1)
  [ -z "$MODEL" ] && MODEL="(unknown)"

  # Count turns (assistant messages)
  ASSISTANT_COUNT=$(jq -r 'select(.type == "assistant") | .type' "$SESSION_LINES" 2>/dev/null | wc -l | tr -d ' ')

  # Extract final result
  FINAL_RESULT=$(jq -r 'select(.type == "result") | {subtype: .subtype, duration_ms: .duration_ms, total_cost_usd: .total_cost_usd, num_turns: .num_turns, stop_reason: .stop_reason, errors: .errors}' "$SESSION_LINES" 2>/dev/null | head -1)
  FINAL_SUBTYPE=$(jq -r 'select(.type == "result") | .subtype // "normal"' "$SESSION_LINES" 2>/dev/null | head -1)
  DURATION_MS=$(jq -r 'select(.type == "result") | .duration_ms // 0' "$SESSION_LINES" 2>/dev/null | head -1)
  COST_USD=$(jq -r 'select(.type == "result") | .total_cost_usd // "?"' "$SESSION_LINES" 2>/dev/null | head -1)
  NUM_TURNS=$(jq -r 'select(.type == "result") | .num_turns // 0' "$SESSION_LINES" 2>/dev/null | head -1)
  STOP_REASON=$(jq -r 'select(.type == "result") | .stop_reason // empty' "$SESSION_LINES" 2>/dev/null | head -1)

  # Format duration
  if [ -n "$DURATION_MS" ] && [ "$DURATION_MS" -gt 0 ] 2>/dev/null; then
    DURATION_SEC=$(( DURATION_MS / 1000 ))
    DURATION_MIN=$(( DURATION_SEC / 60 ))
    DURATION_REMAIN=$(( DURATION_SEC % 60 ))
    DURATION_STR="${DURATION_MIN}m${DURATION_REMAIN}s"
  else
    DURATION_STR="?"
  fi

  # Format cost
  if [ "$COST_USD" != "?" ]; then
    COST_STR="\$$COST_USD"
  else
    COST_STR="?"
  fi

  # Turn budget info
  TURN_STR="$NUM_TURNS"
  if [ "$FINAL_SUBTYPE" = "error_max_turns" ]; then
    TURN_STR="$NUM_TURNS (BUDGET EXCEEDED)"
  fi

  # Stop reason
  STOP_STR="${STOP_REASON:-normal}"
  if [ "$FINAL_SUBTYPE" = "error_max_turns" ]; then
    STOP_STR="tool_use (max_turns)"
  fi

  # Exit status
  EXIT_STR="ok"
  if [ "$FINAL_SUBTYPE" = "error_max_turns" ]; then
    EXIT_STR="error (max_turns)"
  elif echo "$FINAL_SUBTYPE" | grep -q "^error"; then
    EXIT_STR="error"
  fi

  # --- extract tool calls and results ---------------------------------------
  TOOL_CALLS_FILE=$(mktemp)
  trap 'rm -f "$TOOL_CALLS_FILE"' EXIT

  # Parse tool calls from assistant messages
  jq -r '
    select(.type == "assistant")
    | .message.content[]
    | select(.type == "tool_use")
    | [
        .id,
        .name,
        (.input.command // .input.name // .input.pattern // ""),
        (.input.description // "")
      ] | @tsv
  ' "$SESSION_LINES" 2>/dev/null > "$TOOL_CALLS_FILE" || true

  # Parse tool results from user messages
  TOOL_RESULTS_FILE=$(mktemp)
  trap 'rm -f "$TOOL_RESULTS_FILE"' EXIT

  jq -r '
    select(.type == "user")
    | .message.content[]
    | select(.type == "tool_result")
    | [
        .tool_use_id,
        (.is_error|tostring),
        (.content // ""),
        (.tool_use_result.stdout // ""),
        (.tool_use_result.stderr // ""),
        (.tool_use_result.returnCodeInterpretation // "")
      ] | @tsv
  ' "$SESSION_LINES" 2>/dev/null > "$TOOL_RESULTS_FILE" || true

  # Traverse errors from final result
  FINAL_ERRORS=$(jq -r 'select(.type == "result") | .errors[]?' "$SESSION_LINES" 2>/dev/null)

  # --- classify and count tool calls by step --------------------------------
  declare -A STEP_CALLS STEP_ERRORS
  STEP_CALLS_ORDER=()

  while IFS=$'\t' read -r tool_id tool_name cmd_line description; do
    [ -z "$tool_id" ] && continue
    classification=$(classify_call "$tool_name" "$cmd_line")
    step_name=$(step_label "$classification")
    [ -z "${STEP_CALLS[$step_name]}" ] && STEP_CALLS_ORDER+=("$step_name")
    STEP_CALLS[$step_name]=$(( ${STEP_CALLS[$step_name]:-0} + 1 ))

    # Check for error in the corresponding tool result
    error_info=$(grep -F "$tool_id" "$TOOL_RESULTS_FILE" 2>/dev/null | head -1)
    if [ -n "$error_info" ]; then
      is_error=$(echo "$error_info" | cut -f2)
      rci=$(echo "$error_info" | cut -f6)
      if [ "$is_error" = "true" ] || echo "$rci" | grep -qiE "error|not found|no matches|failed"; then
        STEP_ERRORS[$step_name]=$(( ${STEP_ERRORS[$step_name]:-0} + 1 ))
      fi
    fi
  done < "$TOOL_CALLS_FILE"

  # --- collect detailed error info ------------------------------------------
  ERRORS_DETAIL=()
  ERROR_INDEX=0

  while IFS=$'\t' read -r tool_id tool_name cmd_line description; do
    [ -z "$tool_id" ] && continue
    error_info=$(grep -F "$tool_id" "$TOOL_RESULTS_FILE" 2>/dev/null | head -1)
    if [ -n "$error_info" ]; then
      is_error=$(echo "$error_info" | cut -f2)
      content=$(echo "$error_info" | cut -f4)
      stderr=$(echo "$error_info" | cut -f5)
      rci=$(echo "$error_info" | cut -f6)
      stdout=$(echo "$error_info" | cut -f4)
      [ -z "$stdout" ] && stdout=$(echo "$error_info" | cut -f3)

      if [ "$is_error" = "true" ] || [ -n "$rci" ]; then
        # Truncate content for display
        err_summary=""
        if echo "$stdout" | grep -qE '"message"'; then
          err_summary=$(echo "$stdout" | jq -r '.message // .errors[0] // empty' 2>/dev/null | head -c 200)
        fi
        [ -z "$err_summary" ] && err_summary=$(echo "$rci" | head -c 200)
        [ -z "$err_summary" ] && err_summary=$(echo "$stderr" | head -c 200)
        [ -z "$err_summary" ] && err_summary="(no detail)"

        # Get the turn number for this tool call
        turn_num=$(jq -r --arg tid "$tool_id" '
          select(.type == "assistant") as $a
          | $a.message.content[]
          | select(.type == "tool_use" and .id == $tid)
          | $a.message.id
        ' "$SESSION_LINES" 2>/dev/null | head -1)
        turn_idx=$(grep -n "$turn_num" "$SESSION_LINES" 2>/dev/null | head -1 | cut -d: -f1)

        classification=$(classify_call "$tool_name" "$cmd_line")
        step_name=$(step_label "$classification")

        ERRORS_DETAIL+=("$(( ERROR_INDEX + 1 )). [Tool $tool_id] $tool_name ($step_name)")
        ERRORS_DETAIL+=("   Command: $(echo "$cmd_line" | head -c 150)")
        ERRORS_DETAIL+=("   Detail: $err_summary")
        [ -n "$rci" ] && ERRORS_DETAIL+=("   Exit: $rci")
        ERRORS_DETAIL+=("")
        ERROR_INDEX=$(( ERROR_INDEX + 1 ))
      fi
    fi
  done < "$TOOL_CALLS_FILE"

  # Also add final result errors
  if [ -n "$FINAL_ERRORS" ]; then
    while IFS= read -r err_line; do
      [ -z "$err_line" ] && continue
      ERRORS_DETAIL+=("$(( ERROR_INDEX + 1 )). [Final] $err_line")
      ERRORS_DETAIL+=("")
      ERROR_INDEX=$(( ERROR_INDEX + 1 ))
    done <<< "$FINAL_ERRORS"
  fi

  # --- print session header -------------------------------------------------
  echo ""
  echo "  Model:      $MODEL"
  echo "  Turns used: $TURN_STR"
  echo "  Duration:   $DURATION_STR | Cost: $COST_STR"
  echo "  Stop:       $STOP_STR"
  echo "  Exit:       $EXIT_STR"
  echo ""

  # --- print step summary ---------------------------------------------------
  if [ ${#STEP_CALLS_ORDER[@]} -gt 0 ]; then
    printf "  %-25s %8s %8s\n" "Step" "Calls" "Errors"
    printf "  %-25s %8s %8s\n" "----" "-----" "------"
    for step in "${STEP_CALLS_ORDER[@]}"; do
      local calls="${STEP_CALLS[$step]:-0}"
      local errs="${STEP_ERRORS[$step]:-0}"
      local err_display="$errs"
      [ "$errs" -gt 0 ] && err_display="$errs <<<<" || err_display="-"
      printf "  %-25s %8s %8s\n" "$step" "$calls" "$err_display"
    done
    echo ""
  fi

  # --- print error details --------------------------------------------------
  if [ ${#ERRORS_DETAIL[@]} -gt 0 ]; then
    echo "  Errors:"
    hr 10
    for err_line in "${ERRORS_DETAIL[@]}"; do
      echo "  $err_line"
    done
  else
    echo "  No errors detected."
  fi

  # --- print tool usage summary ---------------------------------------------
  echo ""
  echo "  Tool Usage:"
  hr 10

  declare -A TOOL_COUNTS TOOL_ERRORS
  while IFS=$'\t' read -r tool_id tool_name cmd_line description; do
    [ -z "$tool_id" ] && continue
    TOOL_COUNTS[$tool_name]=$(( ${TOOL_COUNTS[$tool_name]:-0} + 1 ))
    error_info=$(grep -F "$tool_id" "$TOOL_RESULTS_FILE" 2>/dev/null | head -1)
    if [ -n "$error_info" ]; then
      is_error=$(echo "$error_info" | cut -f2)
      if [ "$is_error" = "true" ]; then
        TOOL_ERRORS[$tool_name]=$(( ${TOOL_ERRORS[$tool_name]:-0} + 1 ))
      fi
    fi
  done < "$TOOL_CALLS_FILE"

  printf "  %-25s %8s %8s\n" "Tool" "Calls" "Errors"
  printf "  %-25s %8s %8s\n" "----" "-----" "------"
  for tool in "${!TOOL_COUNTS[@]}"; do
    local tc="${TOOL_COUNTS[$tool]}"
    local te="${TOOL_ERRORS[$tool]:-0}"
    te=${te:-0}
    local ed="$te"
    [ "$te" -gt 0 ] && ed="$te <<<<" || ed="-"
    printf "  %-25s %8s %8s\n" "$tool" "$tc" "$ed"
  done

  echo ""
  hr

  # Clean up per-session temp files
  if [ "$SESSION_COUNT" -gt 1 ]; then
    rm -f "$SESSION_LINES"
  fi
done
