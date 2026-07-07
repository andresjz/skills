#!/usr/bin/env bash
# post_review.sh — deterministic posting of review comments for review-pr-clickup
#
# Reads $WORKDIR/findings.jsonl (written by the model with snippet-based
# findings) and $WORKDIR/summary.md (the general review body), resolves line
# numbers mechanically from the actual repo files, and posts them via gh.
#
# The model never computes line numbers or constructs API payloads — it only
# provides judgement (identifying findings, choosing distinctive snippets,
# writing comment bodies). Everything mechanical lives here.
#
# Usage:
#   post_review.sh
#
# Env (read from $WORKDIR/context.env after sourcing it):
#   REPO, PR, SHA, REPO_ROOT, WORKDIR
#
# Input files (under $WORKDIR/):
#   findings.jsonl   — one JSON object per line, fields: path, snippet,
#                      [start_snippet,] [tag,] body
#   summary.md       — the general review body (Option A)
#   context.env      — key=value pairs from prefetch.sh
#   head_sha.txt     — the HEAD commit SHA of the PR
#
# Output:
#   stdout — a single REPORT line (parseable) and human-readable summary
#   Exit 0 on success (fallbacks are still success)
#   Exit 1 on fatal errors (no summary posted at all)

set -uo pipefail

# --- helpers ----------------------------------------------------------------

die() { echo "[FATAL] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

resolve_line() {
  local path="$1" snippet="$2" reporoot="$3"
  local file="$reporoot/$path"
  local line="" count=0

  [ ! -f "$file" ] && { echo ""; return 1; }

  # Try exact snippet
  line=$(grep -n -F "$snippet" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  count=$(grep -c -F "$snippet" "$file" 2>/dev/null || echo 0)
  if [ -n "$line" ] && [ "$count" -eq 1 ]; then
    echo "$line"
    return 0
  fi

  # Try first 40 chars
  local short="${snippet:0:40}"
  line=$(grep -n -F "$short" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  count=$(grep -c -F "$short" "$file" 2>/dev/null || echo 0)
  if [ -n "$line" ] && [ "$count" -eq 1 ]; then
    echo "$line"
    return 0
  fi

  # Try first 20 chars
  short="${snippet:0:20}"
  line=$(grep -n -F "$short" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  count=$(grep -c -F "$short" "$file" 2>/dev/null || echo 0)
  if [ -n "$line" ] && [ "$count" -eq 1 ]; then
    echo "$line"
    return 0
  fi

  # Fuzzy nearby: grep with 20 chars, filter matches within ±10 lines
  # of the first match's location
  local first_match
  first_match=$(grep -n -F "$short" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$first_match" ]; then
    local floor=$(( first_match - 10 ))
    local ceil=$(( first_match + 10 ))
    [ "$floor" -lt 1 ] && floor=1
    # Count matches within range
    local nearby
    nearby=$(grep -n -F "$short" "$file" 2>/dev/null | awk -F: -v fl="$floor" -v ce="$ceil" '$1 >= fl && $1 <= ce' | head -1 | cut -d: -f1)
    if [ -n "$nearby" ]; then
      echo "$nearby"
      return 0
    fi
  fi

  echo ""
  return 1
}

# --- main -------------------------------------------------------------------

WORKDIR="${WORKDIR:-}"
[ -z "$WORKDIR" ] && WORKDIR="${PWD}"

CONTEXT_ENV="$WORKDIR/context.env"
FINDINGS="$WORKDIR/findings.jsonl"
SUMMARY="$WORKDIR/summary.md"
HEAD_SHA_FILE="$WORKDIR/head_sha.txt"

[ -f "$CONTEXT_ENV" ] || die "context.env not found at $CONTEXT_ENV"
[ -f "$FINDINGS" ]    || die "findings.jsonl not found at $FINDINGS"
[ -f "$SUMMARY" ]     || die "summary.md not found at $SUMMARY"
[ -f "$HEAD_SHA_FILE" ] || die "head_sha.txt not found at $HEAD_SHA_FILE"

# shellcheck source=/dev/null
source "$CONTEXT_ENV"

: "${REPO:?REPO not set in context.env}"
: "${PR:?PR not set in context.env}"
: "${REPO_ROOT:?REPO_ROOT not set in context.env}"
: "${SHA:?SHA not set in context.env}"

if [ -z "$SHA" ]; then
  SHA=$(cat "$HEAD_SHA_FILE" 2>/dev/null || echo "")
  [ -z "$SHA" ] && die "SHA is empty in both context.env and head_sha.txt"
fi

info "Posting review for $REPO#$PR (SHA=$SHA)"
info "  findings:    $FINDINGS"
info "  summary:     $SUMMARY"
info "  repo root:   $REPO_ROOT"

# --- Step A: post the general summary --------------------------------------

[ ! -s "$SUMMARY" ] && die "summary.md is empty"

info "Posting summary comment..."
GH_COMMENT_OUT=$(gh pr comment "$PR" --repo "$REPO" --body-file "$SUMMARY" 2>&1)
GH_EXIT=$?
if [ "$GH_EXIT" -ne 0 ]; then
  warn "First summary post failed, retrying with simpler body..."
  # Strip suggestion fences that might cause issues
  sed '/^```suggestion/,/^```/d' "$SUMMARY" > "$WORKDIR/summary_simple.md"
  gh pr comment "$PR" --repo "$REPO" --body-file "$WORKDIR/summary_simple.md" 2>&1
  GH_EXIT2=$?
  if [ "$GH_EXIT2" -ne 0 ]; then
    die "Failed to post summary comment after 2 attempts (exit $GH_EXIT then $GH_EXIT2)"
  fi
fi
info "Summary posted successfully."
SUMMARY_POSTED=true

# --- Step B: resolve and post inline comments -------------------------------

TOTAL=0
POSTED=0
FALLBACK=0
ERRORS=0
FALLBACK_BODY=""
FIRST_FALLBACK=true

while IFS= read -r finding; do
  [ -z "$finding" ] && continue
  TOTAL=$(( TOTAL + 1 ))

  # Parse fields — these must be present
  path=$(echo "$finding" | jq -r '.path // empty' 2>/dev/null)
  snippet=$(echo "$finding" | jq -r '.snippet // empty' 2>/dev/null)
  body=$(echo "$finding" | jq -r '.body // empty' 2>/dev/null)
  start_snippet=$(echo "$finding" | jq -r '.start_snippet // empty' 2>/dev/null)

  [ -z "$path" ]    && { warn "Finding #$TOTAL has no 'path', skipping"; ERRORS=$(( ERRORS + 1 )); continue; }
  [ -z "$snippet" ] && { warn "Finding #$TOTAL has no 'snippet', skipping"; ERRORS=$(( ERRORS + 1 )); continue; }
  [ -z "$body" ]    && { warn "Finding #$TOTAL has no 'body', skipping"; ERRORS=$(( ERRORS + 1 )); continue; }

  # Resolve line number from snippet
  line=$(resolve_line "$path" "$snippet" "$REPO_ROOT")
  res_exit=$?

  # Resolve start_line if start_snippet is present
  start_line=""
  if [ -n "$start_snippet" ]; then
    start_line=$(resolve_line "$path" "$start_snippet" "$REPO_ROOT")
    if [ -z "$start_line" ]; then
      warn "Finding #$TOTAL: start_snippet unresolved for $path, posting as single-line"
      start_line=""
    fi
  fi

  if [ -z "$line" ]; then
    warn "Finding #$TOTAL: snippet '$snippet' not resolvable in $path, falling back to summary"
    FALLBACK=$(( FALLBACK + 1 ))
    if [ "$FIRST_FALLBACK" = true ]; then
      FALLBACK_BODY="### Hallazgos no publicados como inline (snippet no resuelto)\n\n"
      FIRST_FALLBACK=false
    fi
    FALLBACK_BODY="${FALLBACK_BODY}**${path}** — ${body}\n\n"
    continue
  fi

  # Validate start_line < line
  if [ -n "$start_line" ]; then
    if [ "$start_line" -ge "$line" ] 2>/dev/null; then
      warn "Finding #$TOTAL: start_line ($start_line) >= line ($line), posting as single-line"
      start_line=""
    fi
  fi

  # Build payload JSON
  payload_file=$(mktemp)
  if [ -n "$start_line" ]; then
    jq -n \
      --arg body "$body" \
      --arg path "$path" \
      --argjson line "$line" \
      --argjson start_line "$start_line" \
      --arg commit_id "$SHA" \
      '{
        body: $body,
        path: $path,
        line: $line,
        start_line: $start_line,
        commit_id: $commit_id,
        side: "RIGHT",
        start_side: "RIGHT"
      }' > "$payload_file"
  else
    jq -n \
      --arg body "$body" \
      --arg path "$path" \
      --argjson line "$line" \
      --arg commit_id "$SHA" \
      '{
        body: $body,
        path: $path,
        line: $line,
        commit_id: $commit_id,
        side: "RIGHT"
      }' > "$payload_file"
  fi

  # Post inline comment (max 2 attempts)
  posted=false
  for attempt in 1 2; do
    gh api \
      --method POST \
      -H "Accept: application/vnd.github.v3+json" \
      "/repos/$REPO/pulls/$PR/comments" \
      --input "$payload_file" > /dev/null 2>&1
    gh_exit=$?
    if [ "$gh_exit" -eq 0 ]; then
      posted=true
      break
    fi
    if [ "$attempt" -eq 1 ]; then
      warn "Finding #$TOTAL: attempt 1 failed (exit $gh_exit), retrying without start_line..."
      # Retry as single-line (drop start_line/start_side)
      jq -n \
        --arg body "$body" \
        --arg path "$path" \
        --argjson line "$line" \
        --arg commit_id "$SHA" \
        '{
          body: $body,
          path: $path,
          line: $line,
          commit_id: $commit_id,
          side: "RIGHT"
        }' > "$payload_file"
    fi
  done

  rm -f "$payload_file"

  if [ "$posted" = true ]; then
    POSTED=$(( POSTED + 1 ))
    info "Finding #$TOTAL: inline comment posted on $path:$line"
  else
    warn "Finding #$TOTAL: inline comment failed after 2 attempts, falling back to summary"
    FALLBACK=$(( FALLBACK + 1 ))
    if [ "$FIRST_FALLBACK" = true ]; then
      FALLBACK_BODY="### Hallazgos no publicados como inline (error de publicación)\n\n"
      FIRST_FALLBACK=false
    fi
    FALLBACK_BODY="${FALLBACK_BODY}**${path}** — ${body}\n\n"
  fi
done < "$FINDINGS"

# --- Step C: post fallback body if any fallbacks occurred -------------------

if [ "$FALLBACK" -gt 0 ] && [ -n "$FALLBACK_BODY" ]; then
  info "Posting $FALLBACK fallback finding(s) as a follow-up comment..."
  printf "%s" "$FALLBACK_BODY" > "$WORKDIR/summary_fallbacks.md"
  gh pr comment "$PR" --repo "$REPO" --body-file "$WORKDIR/summary_fallbacks.md" 2>&1
  fb_exit=$?
  if [ "$fb_exit" -ne 0 ]; then
    warn "Failed to post fallback comment (exit $fb_exit)"
    ERRORS=$(( ERRORS + 1 ))
  fi
fi

# --- Report ----------------------------------------------------------------

echo ""
echo "============================================"
echo " POST_REVIEW RESULT"
echo "============================================"
echo " Total findings:    $TOTAL"
echo " Inline posted:     $POSTED"
echo " Fallback to sum.:  $FALLBACK"
echo " Errors:            $ERRORS"
echo " Summary posted:    ${SUMMARY_POSTED:-false}"
echo "============================================"
echo "POST_REVIEW_RESULT=total=$TOTAL inline=$POSTED fallback=$FALLBACK errors=$ERRORS summary_posted=${SUMMARY_POSTED:-false}"

if [ "${SUMMARY_POSTED:-false}" = true ]; then
  exit 0
else
  exit 1
fi
