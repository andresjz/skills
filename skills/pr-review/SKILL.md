---
name: pr-review
description: Review an open GitHub Pull Request, analyze changes against relevant .github/instructions, and post structured review comments directly on the PR.
---

# Review Pull Request

## Purpose
Review a specific GitHub Pull Request by fetching its diff, analyzing it against the relevant `.github/instructions` files, and posting structured review comments directly on the PR using the GitHub CLI (`gh`).

## Execution mode (read this first)

This skill runs in **two possible modes**. Detect the mode before doing anything else:

- **CI mode**: the environment variable `CI` is set to `true` (this is the case in the GitHub Actions pipeline that invokes this skill via `claude --print`).
- **Interactive mode**: `CI` is not set (a human is chatting with Claude directly).

**In CI mode there is no human available to answer questions.** `--print` is a single-shot, non-interactive invocation — if this skill ever stops to ask a question and wait for a reply, the run silently wastes its turn budget and ends without doing anything useful. So in CI mode:

- **Never ask for the PR number/repo.** Read them from environment variables (see step 1).
- **Never ask for confirmation before posting.** The pipeline itself is the approval gate (a human triggered the workflow, or reviews the run logs). Post directly once the review is generated.
- **Never wait for user input of any kind.**

In Interactive mode, keep the original behavior: ask for the PR if not given, and ask for confirmation (sí/no) before posting.

## Prerequisites
- `gh` must be authenticated (`gh auth status`)
- The `.github/instructions/` directory must exist with instruction files
- The PR must be open and accessible

## Required workflow

### 1. Resolve PR context

**CI mode**: read directly from environment, do not ask the user anything:
```bash
echo "REPO=$GITHUB_REPOSITORY"
echo "PR=$PR_NUMBER"
echo "BASE=$GITHUB_BASE_REF"
```
If `GITHUB_REPOSITORY` or `PR_NUMBER` is empty, stop and print a clear error (`"[FATAL] Missing GITHUB_REPOSITORY or PR_NUMBER env vars"`) instead of asking a question — there is no one to answer it.

**Interactive mode**: the user must provide a PR URL or `owner/repo#number` format (e.g., `andresjz/API#1`). If not provided, ask for it. Default repo can be inferred from `gh pr view`.

From here on, `$REPO` and `$PR` refer to whichever of the two sources above was used. Persist them once in a shell variable/temp file at the start and reuse — do not re-derive them repeatedly.

**Define an isolated working directory for this run, scoped by repo and PR number.** The runner may execute multiple reviews concurrently (different PRs, or even the same PR re-triggered), so a shared `/tmp/pr_review` path can cause one run to read/overwrite another run's cached files. Always do this before step 3:

```bash
REPO_SAFE=$(echo "$REPO" | tr '/' '_')
WORKDIR="/tmp/pr_review/${REPO_SAFE}/${PR}"
mkdir -p "$WORKDIR"
echo "WORKDIR=$WORKDIR"
```

Every temp file referenced from here on (`meta.json`, `diff.txt`, `files.txt`, `head_sha.txt`, `comments.json`, `inline_comments.json`, `summary.md`, `inline_comment.json`) lives under `$WORKDIR`, not under a fixed shared path.

### 2. Check working tree status (safety guard)
```bash
git status --short
```
If this returns any output, stop and tell the user to commit/stash first (Interactive mode) or fail the step with a clear message (CI mode).
Ignore changes to SKILL.md, AGENTS.md, Taskfile.yml, OPENCODE_SETUP.md.

### 3. Fetch the PR metadata, diff, and comments — once, cache locally

Fetch everything needed in this step and write it to temp files. Do **not** re-fetch the same data later in the run; reuse the files.

```bash
gh pr view "$PR" --repo "$REPO" --json number,title,body,headRefName,baseRefName,author,additions,deletions > "$WORKDIR/meta.json"
gh pr diff "$PR" --repo "$REPO" > "$WORKDIR/diff.txt"
gh pr view "$PR" --repo "$REPO" --json files --jq '.files[].path' > "$WORKDIR/files.txt"
gh pr view "$PR" --repo "$REPO" --json commits --jq '.commits[-1].oid' > "$WORKDIR/head_sha.txt"
gh pr view "$PR" --repo "$REPO" --json comments --jq '.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}' > "$WORKDIR/comments.json"
gh api "/repos/$REPO/pulls/$PR/comments" --jq '.[] | {path: .path, line: .line, body: .body, author: .user.login}' > "$WORKDIR/inline_comments.json"
```

Read `SHA=$(cat "$WORKDIR/head_sha.txt")` once and reuse it for every inline comment in step 6 — do not call `gh pr view --json commits` again.

### 4. Discover and load only relevant instructions (repo-agnostic)

This skill must work on any repo/language/framework. Never hardcode filenames like `java.instructions.md` or `controllers.instructions.md` — discover what actually exists and decide relevance dynamically.

```bash
ls .github/instructions/*.instructions.md 2>/dev/null
```

For each `*.instructions.md` file found, determine whether it applies to this PR:

**Tier 1 — frontmatter `applyTo` (preferred, matches GitHub's Copilot custom-instructions convention):**
Read the YAML frontmatter at the top of the file (between `---` lines). If it has an `applyTo` key with one or more glob patterns (e.g. `applyTo: "**/*.java"` or `applyTo: "**/*Controller.java,**/*Controller.kt"`), match every path in `$WORKDIR/files.txt` against those globs.
- Match → include this instruction file's content when reviewing those files.
- No match on any changed file → skip this instruction file entirely (don't load its content, don't mention it).
- A file with `applyTo` absent, empty, or set to `**` / `*` → treat as **always applicable** (general/repo-wide guidance, e.g. `general.instructions.md`).

**Tier 2 — filename-keyword fallback (only if the repo's instruction files have no frontmatter):**
Strip `.instructions.md` from the filename to get a keyword (e.g. `services`, `migrations`, `frontend`). Include the file if that keyword (singular or plural, case-insensitive) appears in the path of at least one modified file. Always include any file literally named `general.instructions.md` (or equivalent, e.g. `default`, `common`).

Load only the instruction files that matched. State in the review draft which instruction files were considered relevant and why (one line is enough), so the mapping is auditable per repo instead of assumed.

### 5. Generate structured review draft
Analyze the diff + instructions + existing comments and produce structured feedback in Spanish (see "Review goals" below).

**Use existing comments to resolve uncertainty, not just to avoid duplication.** Before flagging something as a finding, check `$WORKDIR/comments.json` and `$WORKDIR/inline_comments.json`:
- If a past comment already explains why something that looks odd is intentional, don't re-flag it — reference the earlier discussion instead if relevant.
- If a past comment raised the same concern and it's still unresolved in the current diff, you can reference it ("como se comentó antes...") rather than presenting it as a new finding.
- When you're genuinely unsure whether something is a real issue (e.g. an unusual pattern that might be a deliberate project convention), check whether prior comments already settled that question before guessing.

**You may read files outside the diff, in a bounded way, to check for patterns and duplicate code.** The original guard against browsing the repo was too strict — some findings (e.g. "this duplicates logic already in `X`", "this doesn't follow the pattern used in `Y`") genuinely need to see another file to be correct instead of speculative. Rules to keep this bounded (see also Anti-loop guards):
- Only read a file outside the diff when it materially changes a specific finding — not for general exploration.
- Prefer a targeted `grep`/`find` for a function/class name over browsing directories.
- Cap it at roughly 5 extra file reads per review. If you need more than that, the finding probably isn't worth chasing further — state the suspicion in the review as a question for the author instead of confirming it exhaustively.

**Interactive mode only**: show the draft to the user and ask:

> **¿Confirmas que quieres publicar esta review en el PR? (sí/no)**
>
> Si dices "sí", se publicará.
> Si dices "no" o quieres modificarlo, indícame los cambios.

**CI mode**: skip this. Go straight to step 6.

### 6. Post the review

**CI mode**: post automatically, no confirmation needed. **Interactive mode**: only after user confirmation.

#### Option A: Post as a PR comment (simple, always works)
Always write the body to a temp file first — never inline multiline content into `--body`, this is a common source of shell-escaping failures that cause retries/loops:
```bash
cat > "$WORKDIR/summary.md" << 'ENDOFFILE'
<review_content>
ENDOFFILE
gh pr comment "$PR" --repo "$REPO" --body-file "$WORKDIR/summary.md"
```

#### Option B: Post inline comments on specific lines (for critical findings)

Use temp JSON files, not process substitution (`<(...)`) — process substitution is not supported by `sh`/`dash` and silently fails on some CI runners, which is a likely source of retry loops:

```bash
SHA=$(cat "$WORKDIR/head_sha.txt")

cat > "$WORKDIR/inline_comment.json" << EOF
{
  "body": "[TAG] Comment text here",
  "path": "src/main/java/.../File.java",
  "line": 42,
  "commit_id": "$SHA",
  "side": "RIGHT"
}
EOF

gh api \
  --method POST \
  -H "Accept: application/vnd.github.v3+json" \
  "/repos/$REPO/pulls/$PR/comments" \
  --input "$WORKDIR/inline_comment.json"
```

**Hard rule to prevent loops:** for a given finding, attempt an inline comment **at most twice** (e.g. the diff line, then one nearby line inside the same hunk if the first is rejected with "could not be resolved"). If both attempts fail, **do not keep guessing lines** — immediately fall back to including that finding in the Option A general PR comment instead, tagged with the file/line in text, and move on to the next finding.

##### Using `suggestion` blocks (one-click auto-apply)

GitHub renders a fenced ```` ```suggestion ```` code block inside an inline PR comment as an "Apply suggestion" button, letting the PR author accept the exact replacement with one click. Use this whenever the fix is **mechanical and safe to apply verbatim** — e.g. a null check, a typo, a wrong variable, a missing import, a formatting issue, a simple off-by-one. This is the single highest-leverage change reviewers can make, since it turns a comment into a one-click fix instead of manual retyping.

The body of the comment is: a short explanation, then a suggestion fence containing **only** the corrected code that should replace the commented line(s) — nothing else inside the fence (no comments-about-the-code, no partial line).

```
[BUG] `user` puede ser null aquí si el lookup falla; agrega el check antes de usarlo.

```suggestion
if (user == null) {
    return Optional.empty();
}
```
```

For a **single line** fix, comment on that `line` as usual (see JSON payload above) and the suggestion fence must contain exactly one line (the full replacement for that line).

For a **multi-line** fix, add `start_line` to the JSON payload (in addition to `line`, which becomes the end of the range) so the range being replaced is unambiguous:
```json
{
  "body": "[PATTERN] ...\n\n```suggestion\n<replacement for the whole range>\n```",
  "path": "src/.../File.java",
  "start_line": 38,
  "line": 42,
  "commit_id": "$SHA",
  "side": "RIGHT",
  "start_side": "RIGHT"
}
```
The suggestion fence must contain the **complete replacement for the entire `start_line..line` range**, not just the changed portion — GitHub replaces the whole commented range with the fence content.

**When NOT to use `suggestion`:** architectural/pattern changes that touch multiple files, migrations that need manual judgment (e.g. backfill strategy, data volume considerations), renames that require consistency checks elsewhere in the codebase, or anything where auto-applying without further thought could introduce a new inconsistency. In those cases keep the code example as a plain fenced block (no `suggestion` tag) — informative, not one-click-appliable — as before.

#### Option C: Post a review with approval or request changes
```bash
gh pr review "$PR" --repo "$REPO" --approve --body "<message>"
gh pr review "$PR" --repo "$REPO" --request-changes --body "<message>"
```

### 7. Cleanup

This is a **mandatory last step**, always run — whether the review was posted, skipped, or the run failed partway through. The concern is narrow: **empty only the temp files this skill itself created during the run** — nothing else in `/tmp`.

```bash
for f in "$WORKDIR/meta.json" \
         "$WORKDIR/diff.txt" \
         "$WORKDIR/files.txt" \
         "$WORKDIR/head_sha.txt" \
         "$WORKDIR/comments.json" \
         "$WORKDIR/inline_comments.json" \
         "$WORKDIR/summary.md" \
         "$WORKDIR/inline_comment.json"; do
  [ -f "$f" ] && echo "" > "$f"
done
```

Do this as the very last action, after any `gh` posting calls have completed (success or failure) — never empty these files mid-run, since later steps still read from them. Don't glob or delete anything else under `$WORKDIR` — only the files this skill wrote.

## Review goals

You are a senior code reviewer reviewing a Pull Request.

Use:
- The PR diff (`$WORKDIR/diff.txt`)
- The PR metadata (title, description, author)
- The relevant `.github/instructions` for modified files
- Existing comments on the PR (to avoid duplication)

Produce a structured review in Spanish with:

### 0. Puntuación de Calidad
Always open the review with an overall quality score for the PR, using this exact format:

```
## Puntuación de Calidad
⭐⭐⭐⭐ — [Justificación de 1-2 líneas, basada en los hallazgos concretos de las secciones siguientes, no genérica.]
```

Scale (pick one, use the criterion closest to the PR's actual state — this is stack-agnostic, applies equally to backend, frontend, infra, etc.):

| Puntuación | Criterio |
|---|---|
| ⭐ | Introduce bugs o rompe patrones críticos |
| ⭐⭐ | Varias inconsistencias con estándares |
| ⭐⭐⭐ | Funcional pero con oportunidades de mejora |
| ⭐⭐⭐⭐ | Buenas prácticas; observaciones menores |
| ⭐⭐⭐⭐⭐ | Código ejemplar; sigue todos los estándares |

The justification must reference what was actually found (e.g. "hay 2 bugs potenciales y falta cobertura de tests" or "sigue el patrón del proyecto, solo detalles de naming"), never a generic phrase like "buen trabajo" without grounding it in the sections below. Determine the score **after** doing the file-by-file and guideline-compliance analysis, not before — the score must follow from the findings, not the other way around.

### 1. Summary of changes
- 3 to 7 bullets describing the key changes in the PR.

### 2. File-by-file feedback
For each modified file, identify:
- Probable or confirmed bugs.
- Missing edge cases.
- Performance, concurrency, or security concerns.

### 3. Guideline compliance
Verify compliance against **whatever instruction files were loaded in step 4** — one subsection per loaded instruction file, using that file's own name/topic as the heading (e.g. if the repo has `frontend.instructions.md` and `terraform.instructions.md`, review against those; do not assume a Java/API-style breakdown by controllers/services/entities/DTOs unless the repo's instructions actually define those categories).

### 4. Testing gaps
Identify missing or weak tests in the PR.
Propose concrete test cases where needed.

### 5. Suggested improvements
Propose practical improvements such as:
- Small refactors.
- Naming improvements.
- Helper extraction.
- Better module organization.

## Writing actionable comments — include resolution examples

Every `[BUG]`, `[MIGRATION]`, `[PATTERN]`, and `[BREAKING]` comment should include a **code example** showing how to fix or mitigate the issue.

`[MIGRATION]` is not backend/SQL-specific — use it for **any structural, hard-to-reverse change**: a DB migration, an infra state change (Terraform/Pulumi), a config schema change, a queue/topic rename, a feature-flag rollout step, a frontend build/routing migration, etc. The concrete example should be written in whatever language/format the change actually is (SQL, HCL, YAML, JSON, shell), not defaulted to SQL.

**Bad — just the problem (backend/DB example):**
> `[MIGRATION]` El DROP COLUMN no tiene backfill. Sugiero agregar un UPDATE de backfill como precaución.

**Good — problem + concrete fix (backend/DB example):**
> `[MIGRATION]` El DROP COLUMN no tiene backfill. Agrega un UPDATE de backfill antes del DROP:
>
> ```sql
> UPDATE notifications
> SET message_data = (
>     COALESCE(message_data::jsonb, '{}'::jsonb) ||
>     jsonb_build_object('unitType', unit_type)
> )::text
> WHERE unit_type IS NOT NULL;
>
> ALTER TABLE notifications DROP COLUMN IF EXISTS unit_type;
> ```

**Good — problem + concrete fix (infra example, same principle in a non-backend repo):**
> `[MIGRATION]` Este cambio de `instance_type` en Terraform va a forzar recreación del recurso (no in-place update), lo que causa downtime. Usa `lifecycle.create_before_destroy` o migra por etapas:
>
> ```hcl
> resource "aws_instance" "app" {
>   instance_type = "t3.large"
>   lifecycle {
>     create_before_destroy = true
>   }
> }
> ```

The two examples above illustrate the same tag applied to different stacks — pick the format that matches the actual repo, don't force SQL onto a non-backend change.

Guía por tipo de hallazgo:

| Tag | Qué incluir en el ejemplo | ¿`suggestion` block? |
|---|---|---|
| `[BUG]` | Fragmento de código corregido (antes/después) | Sí, si el fix es mecánico y de una sola ubicación (null check, variable equivocada, off-by-one) |
| `[MIGRATION]` | El cambio estructural corregido en el formato que corresponda al repo (SQL para migraciones de BD, HCL/YAML para infra, JSON schema para config, etc.), incluyendo estrategia de rollback/backfill si aplica | No — casi siempre requiere juicio (volumen de datos, ventana de downtime, orden de despliegue) |
| `[PATTERN]` | Cómo debería verse según el patrón del proyecto (código refactorizado) | No, salvo que el cambio sea trivial y contenido en el rango comentado |
| `[BREAKING]` | Estrategia de migración para consumidores (código de ejemplo del lado cliente, o notas de versión si no aplica código) | No |
| `[IMPROVEMENT]` | Alternativa concreta (código refactorizado, test propuesto) | Solo si es un refactor pequeño y autocontenido |
| `[SECURITY]` | Código vulnerable + versión segura | Sí, si la corrección es autocontenida en las líneas comentadas |
| `[STYLE]` | Opcional — solo si el cambio es muy simple de mostrar | Sí — es el caso ideal para `suggestion` |

## Output rules
- Respond in Spanish.
- Use code blocks for examples.
- Be specific and actionable.
- Prefer concrete findings over generic praise.
- If there are no issues, say so explicitly and explain why.
- The review should be posted as a PR comment or inline comments via `gh`.

## Anti-loop guards (hard limits)
- Reading outside the PR diff is allowed **only** in the bounded way described in step 5 (verifying a specific pattern/duplication finding, capped at ~5 extra file reads, targeted grep over browsing). Do not use it as general exploration.
- Do not broaden the task beyond the PR scope.
- Do not repeat the same command or reasoning path.
- Fetch PR metadata/diff/comments **once** (step 3) and reuse the cached files in `$WORKDIR` — never re-fetch.
- If the diff is large (>1000 lines), prioritize the files most likely to carry risk for *this* repo — infer from what actually changed and from which loaded instruction files flagged them as sensitive (e.g. auth/security-related code, data access/migration files, public API contracts, infra state) rather than assuming a fixed backend layer like "services/controllers". Explicitly state which files were skipped and why.
- If information is missing, state the limitation instead of guessing.
- Limit every tool call to a maximum of **2 attempts**. On the first failure, print the full output/error and explain why. If it fails a second time, skip it and continue — never retry a third time with a variation.
- Inline comments: max **2 attempts per finding** (see Option B). After that, fall back to a general comment and move on.
- **CI mode never blocks on a question.** If at any point the instructions below seem to require waiting for a human, prefer the CI-mode default from the "Execution mode" section over stalling.
- Global budget: if you notice you are repeating the same class of action (e.g. retrying inline comments) more than ~5 times across the whole run, stop attempting inline comments entirely, note it in the summary comment, and finish.
- **Always run step 7 (cleanup)** before ending, regardless of how the run went — emptying the working files is not optional, even on early exit/error paths.

## Usage examples

**CI (GitHub Actions, env vars already set: `GITHUB_REPOSITORY`, `PR_NUMBER`, `GITHUB_BASE_REF`, `CI=true`):**
```bash
claude \
  --print \
  --dangerously-skip-permissions \
  --verbose \
  --output-format stream-json \
  --max-turns 40 \
  --allowedTools "Bash(git:*)" \
  --allowedTools "Bash(gh:*)" \
  --allowedTools "Bash(jq:*)" \
  --allowedTools "Bash(ls:*)" \
  --allowedTools "Bash(cat:*)" \
  --allowedTools "Bash(find:*)" \
  --allowedTools "Bash(grep:*)" \
  --allowedTools "Bash(head:*)" \
  --allowedTools "Bash(mkdir:*)" \
  --allowedTools "Bash(tr:*)" \
  --allowedTools "Bash(echo:*)" \
  --allowedTools "Bash(bash:*)" \
  --allowedTools "Read" \
  --allowedTools "Write" \
  < .claude/skills/pr-review/SKILL.md
```

**Interactive:**
- User: "Review PR myorg/myrepo#42"
- User: "Review https://github.com/myorg/myrepo/pull/42"
- User: "Review the current PR (assumes `gh pr view` works on the checked-out branch)"
