#!/usr/bin/env bash
# prefetch.sh — single source of truth for review-pr-clickup steps 1, 2, 3, 3.5
#
# Resolves REPO/PR, computes an isolated WORKDIR, guards against a dirty
# working tree, fetches PR metadata/diff/comments via `gh`, and extracts +
# fetches a ClickUp ticket if one is referenced. All of this is mechanical
# (no judgement required), so it lives here as a single script instead of
# being described in prose for an agent to reproduce — that duplication
# (workflow bash vs skill prose) was the source of path-related confusion.
#
# Idempotent by design: safe to re-run at any point (e.g. if you lose track
# of WORKDIR mid-run) — already-fetched files are not fetched again unless
# --force-refetch is passed.
#
# Usage:
#   prefetch.sh [--repo OWNER/REPO] [--pr NUMBER] [--force-refetch]
#               [--print-workdir-only] [--force] [--help]
#
# Env fallback (used when the matching flag is not passed):
#   REPO or GITHUB_REPOSITORY   owner/repo
#   PR or PR_NUMBER             PR number
#   REPO_ROOT                   absolute path to the checked-out repo (defaults
#                               to $PWD -- the repo is already cloned by the
#                               time this runs, we never clone/copy it again)
#   CLICKUP_TOKEN               ClickUp API token (optional)
#   CLICKUP_TEAM_ID             ClickUp team id (optional)
#   CI                          "true" selects CI semantics for the dirty-tree guard
#
# Output: a final key=value block on stdout (MODE, REPO, PR, WORKDIR, SHA,
# TICKET_ID, CLICKUP_STATUS, REPO_ROOT), also persisted to "$WORKDIR/context.env".
# REPO_ROOT is the authoritative absolute path for any later filesystem read
# of the repo itself (e.g. .github/instructions/) -- always use it instead of
# a bare relative path, since the caller's cwd at that later point isn't
# guaranteed to still be the repo root.

set -uo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
PR="${PR:-${PR_NUMBER:-}}"
FORCE_REFETCH=false
PRINT_WORKDIR_ONLY=false
FORCE=false

print_help() {
  cat <<'HELP'
prefetch.sh — resolve REPO/PR/WORKDIR and fetch PR + ClickUp context once.

Usage:
  prefetch.sh [--repo OWNER/REPO] [--pr NUMBER] [--force-refetch]
              [--print-workdir-only] [--force] [--help]

Env fallback: REPO/GITHUB_REPOSITORY, PR/PR_NUMBER, CLICKUP_TOKEN,
CLICKUP_TEAM_ID, CI.

Idempotent: safe to re-run. Use --print-workdir-only to cheaply recover the
WORKDIR path (no network calls) if you lose track of it mid-run.
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --force-refetch) FORCE_REFETCH=true; shift ;;
    --print-workdir-only) PRINT_WORKDIR_ONLY=true; shift ;;
    --force) FORCE=true; shift ;;
    --help|-h) print_help; exit 0 ;;
    *) echo "[FATAL] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$PR" ]; then
  echo "[FATAL] Missing REPO or PR (REPO='$REPO' PR='$PR'). Pass --repo/--pr or set REPO/PR (or GITHUB_REPOSITORY/PR_NUMBER)." >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-$PWD}"

REPO_SAFE=$(echo "$REPO" | tr '/' '_')
WORKDIR="/tmp/pr_review/${REPO_SAFE}/${PR}"
mkdir -p "$WORKDIR"

if [ "$PRINT_WORKDIR_ONLY" = true ]; then
  echo "WORKDIR=$WORKDIR"
  exit 0
fi

MODE="INTERACTIVE"
if [ "${CI:-}" = "true" ]; then
  MODE="CI"
fi

# --- step 2: dirty working tree guard -------------------------------------
# `git -C "$REPO_ROOT"` instead of a bare `git status` -- never depend on the
# caller's cwd happening to be the repo root.
# Ignore changes to files the skill itself might touch across runs.
IGNORED_FILES='SKILL.md|AGENTS.md|Taskfile.yml|OPENCODE_SETUP.md'
DIRTY=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | grep -Ev "($IGNORED_FILES)\$" || true)
if [ -n "$DIRTY" ] && [ "$FORCE" != true ]; then
  if [ "$MODE" = "CI" ]; then
    echo "[FATAL] Working tree is dirty in CI mode (should be a fresh checkout):" >&2
    echo "$DIRTY" >&2
    exit 1
  else
    echo "[WARN] Working tree has uncommitted changes; commit/stash first, or re-run with --force:" >&2
    echo "$DIRTY" >&2
    exit 2
  fi
fi

# --- step 3: fetch PR metadata/diff/comments once, cache to disk ----------
fetch_if_missing() {
  local file="$1"
  shift
  if [ "$FORCE_REFETCH" = true ] || [ ! -s "$file" ]; then
    "$@" > "$file"
  fi
}

fetch_if_missing "$WORKDIR/meta.json" \
  gh pr view "$PR" --repo "$REPO" --json number,title,body,headRefName,baseRefName,author,additions,deletions
fetch_if_missing "$WORKDIR/diff.txt" \
  gh pr diff "$PR" --repo "$REPO"
fetch_if_missing "$WORKDIR/files.txt" \
  gh pr view "$PR" --repo "$REPO" --json files --jq '.files[].path'
fetch_if_missing "$WORKDIR/head_sha.txt" \
  gh pr view "$PR" --repo "$REPO" --json commits --jq '.commits[-1].oid'
fetch_if_missing "$WORKDIR/comments.json" \
  gh pr view "$PR" --repo "$REPO" --json comments --jq '.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}'
fetch_if_missing "$WORKDIR/inline_comments.json" \
  gh api "/repos/$REPO/pulls/$PR/comments" --jq '.[] | {path: .path, line: .line, body: .body, author: .user.login}'

SHA=$(cat "$WORKDIR/head_sha.txt" 2>/dev/null || echo "")

# --- step 3.5: ClickUp ticket extraction, best-effort/never fatal ---------
TICKET_ID=""
CLICKUP_STATUS="skipped"

if [ -f "$WORKDIR/clickup_tickets.txt" ] && [ "$FORCE_REFETCH" != true ]; then
  TICKET_ID=$(cat "$WORKDIR/clickup_tickets.txt")
  if [ -s "$WORKDIR/clickup_summary.txt" ]; then
    CLICKUP_STATUS="fetched"
  fi
elif command -v clickup-cli >/dev/null 2>&1 && [ -n "${CLICKUP_TOKEN:-}" ] && [ -n "${CLICKUP_TEAM_ID:-}" ]; then
  BRANCH=$(jq -r '.headRefName' "$WORKDIR/meta.json" 2>/dev/null || echo "")
  TICKET_ID=$(echo "$BRANCH" | grep -oE 'CU-[a-zA-Z0-9]+' | head -1 || true)

  if [ -z "$TICKET_ID" ]; then
    PR_BODY=$(jq -r '.body // empty' "$WORKDIR/meta.json" 2>/dev/null || echo "")
    TICKET_ID=$(echo "$PR_BODY" | grep -oE 'CU-[a-zA-Z0-9]+' | head -1 || true)
  fi

  if [ -n "$TICKET_ID" ]; then
    echo "$TICKET_ID" > "$WORKDIR/clickup_tickets.txt"
    if clickup-cli task summary "$TICKET_ID" --team "$CLICKUP_TEAM_ID" > "$WORKDIR/clickup_summary.txt" 2>&1; then
      CLICKUP_STATUS="fetched"
    else
      rm -f "$WORKDIR/clickup_summary.txt"
      CLICKUP_STATUS="error"
    fi
  else
    CLICKUP_STATUS="no_ticket"
  fi
else
  CLICKUP_STATUS="skipped"
fi

# --- final report -----------------------------------------------------------
{
  echo "MODE=$MODE"
  echo "REPO=$REPO"
  echo "PR=$PR"
  echo "WORKDIR=$WORKDIR"
  echo "SHA=$SHA"
  echo "TICKET_ID=$TICKET_ID"
  echo "CLICKUP_STATUS=$CLICKUP_STATUS"
  echo "REPO_ROOT=$REPO_ROOT"
} | tee "$WORKDIR/context.env"
