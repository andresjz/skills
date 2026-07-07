---
name: review-pr-clickup
description: Revisa un PR de GitHub con contexto de ticket ClickUp - analiza cambios contra requisitos y criterios de aceptación del ticket
compatibility: Requiere gh CLI (autenticado), git, jq, clickup-cli (con CLICKUP_TOKEN y CLICKUP_TEAM_ID). El directorio .github/instructions/ debe existir en el repo objetivo.
metadata:
  version: "1.1.0"
---

# Review Pull Request con Contexto ClickUp

## Purpose
Review a specific GitHub Pull Request by fetching its diff, analyzing it against the relevant `.github/instructions` files and ClickUp ticket requirements, and posting structured review comments directly on the PR using the GitHub CLI (`gh`).

## Step 1: Resolve context — always run the bundled script first

Steps 1, 2, 3, and 3.5 of the old workflow (resolving `REPO`/`PR`, computing an isolated `WORKDIR`, checking the working tree is clean, fetching the PR diff/metadata/comments via `gh`, and detecting/fetching a ClickUp ticket) are **100% mechanical** — no judgement is required, so they are implemented once as a bundled script instead of being described in prose for you to reproduce by hand. Reproducing this logic yourself (recomputing `WORKDIR`, re-running individual `gh` calls) is exactly what causes drift and confusion about paths later in a run — always defer to the script instead.

**Run this as your first action, every time, regardless of mode:**

```bash
bash "$(dirname "$0")/../scripts/prefetch.sh" --repo "$REPO" --pr "$PR"
```

In practice, resolve the path to `scripts/prefetch.sh` relative to wherever this `SKILL.md` was installed (e.g. `~/.claude/skills/review-pr-clickup/scripts/prefetch.sh`) and pass `--repo owner/repo --pr NUMBER`. If a caller (e.g. a CI pipeline) already ran this exact script before invoking you and told you so, you do not need to run it again — but if you are ever unsure, **just run it anyway**: it is idempotent (already-fetched files are reused, not re-fetched) and safe to call as many times as you want, including with no arguments beyond `--print-workdir-only` if you just need to recover `WORKDIR` cheaply without hitting the network.

The script prints (and persists to `$WORKDIR/context.env`) a final block like:
```
MODE=CI|INTERACTIVE
REPO=owner/repo
PR=123
WORKDIR=/tmp/pr_review/owner_repo/123
SHA=<head-commit-sha>
TICKET_ID=CU-xxxxxxxx (or empty)
CLICKUP_STATUS=fetched|skipped|error|no_ticket
REPO_ROOT=/absolute/path/to/checked-out/repo
```

Use these values as authoritative — never recompute `WORKDIR` by hand, never re-derive `REPO`/`PR` from context, never guess `SHA`. If you need any of them again later in the run, either keep them from this output or re-run `--print-workdir-only` to recover `WORKDIR` and read the rest from `$WORKDIR/context.env`.

**`REPO_ROOT` is the absolute path to the already-checked-out repo — the repo is never cloned or copied again by this skill.** Whenever you need to read a file that lives in the repo itself (not a fetched artifact under `WORKDIR`) — e.g. `.github/instructions/`, or any source file — always prefix the path with `$REPO_ROOT` (e.g. `"$REPO_ROOT/.github/instructions"`). Never use a bare relative path for this: your shell's cwd at that point in the run is not guaranteed to still be the repo root (you may have `cd`ed into `$WORKDIR` earlier to inspect a fetched file), and that ambiguity is exactly what caused instruction files to go undetected in a real run despite being present in the repo.

**Exit codes to handle:**
- `0`: success, proceed to step 4.
- `1`: fatal — missing `REPO`/`PR`, or a dirty working tree in CI mode. Print the script's own error output and stop; do not try to work around it.
- `2`: dirty working tree in interactive mode. Tell the user to commit/stash first (or re-run yourself with `--force` only if the user explicitly confirms that's fine).

**No PR given (interactive mode only):** if you don't have a `--repo`/`--pr` yet, ask the user for a PR URL or `owner/repo#number` (e.g. `andresjz/API#1`) before running the script. In CI mode, `REPO`/`PR` come from `GITHUB_REPOSITORY`/`PR_NUMBER` env vars, which the script reads automatically — never ask a question in CI mode (see below).

**Mode and posting behavior**, from the script's `MODE=` output:
- **`MODE=CI`**: never ask for confirmation before posting — the pipeline itself is the approval gate. Post the review directly once generated (step 6). Never wait for user input of any kind.
- **`MODE=INTERACTIVE`**: show the draft to the user and ask for confirmation (see step 5) before posting.

## Prerequisites
- `gh` must be authenticated (`gh auth status`)
- `clickup-cli` must be installed and accessible in PATH
- `CLICKUP_TOKEN` environment variable must be set for ClickUp authentication
- `CLICKUP_TEAM_ID` environment variable must be set (e.g., `90111366728`)
- The `.github/instructions/` directory must exist with instruction files
- The PR must be open and accessible

## Required workflow

Every temp file referenced from here on (`meta.json`, `diff.txt`, `files.txt`, `head_sha.txt`, `comments.json`, `inline_comments.json`, `clickup_tickets.txt`, `clickup_summary.txt`, `context.env`, `summary.md`, `summary_simple.md`, `summary_fallbacks.md`, `findings.jsonl`) lives under the `WORKDIR` printed by `scripts/prefetch.sh` in step 1 above — never under a different or hand-computed path.

### 4. Discover and load only relevant instructions (repo-agnostic)

This skill must work on any repo/language/framework. Never hardcode filenames like `java.instructions.md` or `controllers.instructions.md` — discover what actually exists and decide relevance dynamically.

```bash
ls "$REPO_ROOT/.github/instructions"/*.md 2>/dev/null
```

**Always anchor this to `$REPO_ROOT` (from step 1's output), never a bare relative path** — see the note on `REPO_ROOT` in step 1.

**Do not restrict this to `*.instructions.md` only.** Some repos name their instruction files plainly (e.g. `coding-standards.md`, `security.md`) without the `.instructions.md` suffix or any frontmatter — those are still valid instruction files and must be discovered too. If the glob above returns nothing, that means the directory has no `.md` files at all (or doesn't exist) — don't assume "no instructions" without having actually run it.

For each `*.md` file found, determine whether it applies to this PR:

**Tier 1 — frontmatter `applyTo` (preferred, matches GitHub's Copilot custom-instructions convention):**
Read the YAML frontmatter at the top of the file (between `---` lines). If it has an `applyTo` key with one or more glob patterns (e.g. `applyTo: "**/*.java"` or `applyTo: "**/*Controller.java,**/*Controller.kt"`), match every path in `$WORKDIR/files.txt` against those globs.
- Match → include this instruction file's content when reviewing those files.
- No match on any changed file → skip this instruction file entirely (don't load its content, don't mention it).
- A file with `applyTo` absent, empty, or set to `**` / `*` → treat as **always applicable** (general/repo-wide guidance, e.g. `general.instructions.md`).

**Tier 2 — filename-keyword fallback (only if the file has no frontmatter, or no `applyTo` key):**
Strip the extension (`.md` or `.instructions.md`) from the filename to get a keyword.
- If the keyword names a specific technology/module/layer (e.g. `services`, `migrations`, `frontend`, `terraform`), include the file only if that keyword (singular or plural, case-insensitive) appears in the path of at least one modified file.
- If the keyword instead names general, stack-agnostic engineering practice — e.g. `general`, `default`, `common`, `coding-standards`, `standards`, `guidelines`, `conventions`, `style`, `security`, `commits` — treat it as **always applicable**, same as an explicit `applyTo: "**"`. Read the first few lines of the file if the filename alone is ambiguous: content that states rules "toda PR debe cumplir" / "every PR must follow" (i.e. project-wide, not tied to one file type) is general guidance regardless of its exact filename.
- When genuinely unsure whether a no-frontmatter file is general or scoped, prefer including it — a false positive here only adds an extra guideline check; a false negative silently drops real project standards from the review, which is the worse failure.

Load only the instruction files that matched. State in the review draft which instruction files were considered relevant and why (one line is enough), so the mapping is auditable per repo instead of assumed.

### 5. Generate structured review draft
Analyze the diff + instructions + ClickUp ticket context + existing comments and produce structured feedback in Spanish (see "Review goals" below).

**Use existing comments to resolve uncertainty, not just to avoid duplication.** Before flagging something as a finding, check `$WORKDIR/comments.json` and `$WORKDIR/inline_comments.json`:
- If a past comment already explains why something that looks odd is intentional, don't re-flag it — reference the earlier discussion instead if relevant.
- If a past comment raised the same concern and it's still unresolved in the current diff, you can reference it ("como se comentó antes...") rather than presenting it as a new finding.
- When you're genuinely unsure whether something is a real issue (e.g. an unusual pattern that might be a deliberate project convention), check whether prior comments already settled that question before guessing.

**Use ClickUp ticket context to validate implementation:**
If `$WORKDIR/clickup_summary.txt` exists and contains ticket data:
- Read the ticket description to understand the requirements
- Identify "Alcance" (Scope) section to see which routes/modules should be modified
- Identify "Resultado esperado" (Expected result) to verify the PR implements it
- Check if "Replicar" (Replication steps) section exists and verify the PR fixes the described issue
- Flag if the PR modifies files not mentioned in the scope without clear justification
- Verify that validation logic matches what the ticket describes (e.g., case-insensitive email validation)

**You may read files outside the diff, in a bounded way, to check for patterns and duplicate code.** The original guard against browsing the repo was too strict — some findings (e.g. "this duplicates logic already in `X`", "this doesn't follow the pattern used in `Y`") genuinely need to see another file to be correct instead of speculative. Rules to keep this bounded (see also Anti-loop guards):
- Always resolve these paths from `$REPO_ROOT` (e.g. `"$REPO_ROOT/src/..."`), same as instruction files in step 4 — never a bare relative path.
- Only read a file outside the diff when it materially changes a specific finding — not for general exploration.
- Prefer a targeted `grep`/`find` for a function/class name over browsing directories.
- Cap it at roughly 5 extra file reads per review. If you need more than that, the finding probably isn't worth chasing further — state the suspicion in the review as a question for the author instead of confirming it exhaustively.

**Interactive mode only**: show the draft to the user and ask:

> **¿Confirmas que quieres publicar esta review en el PR? (sí/no)**
>
> Si dices "sí", se publicará.
> Si dices "no" o quieres modificarlo, indícame los cambios.

**CI mode**: skip this. Go straight to step 6.

**Prepare inline-comment candidates while you analyze, but write them in one batch, not one tool call per finding.** For every finding that qualifies for an inline comment (see the tag guide in "Writing actionable comments"), determine its `path`/`snippet`/`tag`/`body` **right when you identify it** — while you're still looking at that exact diff hunk — but keep it in your own working notes for now. Only after you've finished analyzing every file, write **all** collected findings to `$WORKDIR/findings.jsonl` in a **single** `Bash` call (one heredoc, one line per finding). **Never make a separate `Bash` tool call per finding to append to this file** — each tool call consumes a turn from your budget, and on a large PR with many findings this can exhaust it before you ever reach step 6 (posting), resulting in *zero* comments posted at all, not even the general summary. This is stack-agnostic: it happens on any large PR regardless of language.

**You do not compute line numbers — write a distinctive `snippet` instead.** The `post_review.sh` script (step 6) resolves snippets to line numbers mechanically. Choose the most unique substring on the exact line you're commenting on — a function/method call, string literal, or variable assignment that appears only once in that file. Avoid single common tokens (`}`, `);`, `pass`, `return`, `null`) that repeat throughout any file. The more distinctive, the more reliable the resolution.

**For multi-line suggestion blocks**, add `start_snippet` with the first line of the range (in addition to `snippet` which remains the last line). The script will resolve both and build the correct range payload.

Write all findings at once (single call, one JSON object per line — JSONL):
```bash
cat > "$WORKDIR/findings.jsonl" << EOF
{"path": "<path/to/file>", "snippet": "<distinctive substring from the exact line>", "tag": "BUG", "body": "[BUG] full comment body here, including any suggestion fence"}
{"path": "<path/to/other-file>", "snippet": "<last line of range>", "start_snippet": "<first line of range>", "tag": "PATTERN", "body": "[PATTERN] another finding's full comment body here"}
EOF
```
By the time you reach step 6, `findings.jsonl` has every inline-comment candidate's identifying information — the script resolves line numbers and posts automatically.

### 6. Post the review

**CI mode**: post automatically, no confirmation needed. **Interactive mode**: only after user confirmation.

All posting logic is handled by `scripts/post_review.sh` — a deterministic script that:
1. Reads `$WORKDIR/findings.jsonl` (written in step 5) and `$WORKDIR/summary.md`
2. Resolves each finding's `snippet` to a real line number via `grep -n -F`
3. Posts the summary via `gh pr comment` (Option A)
4. Posts each inline comment via `gh api POST .../pulls/.../comments` (Option B)
5. Retries once on failure, falls back to a follow-up general comment if inline fails
6. Reports results to stdout

```bash
bash "$(dirname "$0")/../scripts/post_review.sh"
```

**Exit codes:** `post_review.sh` exits 0 on success (including partial success with fallbacks), or 1 if the summary comment itself could not be posted.

**CI mode:** consider running `post_review.sh` with `POST_REVIEW_DISABLE_INLINE=true` to skip inline comments entirely if you only want the general summary (reduces API calls and CI time).

### 7. Cleanup

This is a **mandatory last step**, always run — whether the review was posted, skipped, or the run failed partway through. The concern is narrow: **empty only the temp files this skill itself created during the run** — nothing else in `/tmp`.

```bash
for f in "$WORKDIR/meta.json" \
         "$WORKDIR/diff.txt" \
         "$WORKDIR/files.txt" \
         "$WORKDIR/head_sha.txt" \
         "$WORKDIR/comments.json" \
         "$WORKDIR/inline_comments.json" \
         "$WORKDIR/clickup_tickets.txt" \
         "$WORKDIR/clickup_summary.txt" \
         "$WORKDIR/context.env" \
         "$WORKDIR/summary.md" \
         "$WORKDIR/summary_simple.md" \
         "$WORKDIR/summary_fallbacks.md" \
         "$WORKDIR/findings.jsonl"; do
  [ -f "$f" ] && echo "" > "$f"
done
```

Do this as the very last action, after any `gh` posting calls have completed (success or failure) — never empty these files mid-run, since later steps still read from them. Don't glob or delete anything else under `$WORKDIR` — only the files this skill wrote.

## Review goals

You are a senior code reviewer reviewing a Pull Request.

Use:
- The PR diff (`$WORKDIR/diff.txt`)
- The PR metadata (title, description, author)
- The ClickUp ticket context (`$WORKDIR/clickup_summary.txt`) if available
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

### 6. Contexto del Ticket ClickUp
Include this section **only if** ClickUp ticket data was successfully fetched (i.e., `$WORKDIR/clickup_summary.txt` exists and contains valid data).

Parse the summary file and present:

```markdown
### 6. Contexto del Ticket ClickUp
**Ticket**: [CU-XXXXXXXX](https://app.clickup.com/t/XXXXXXXX)
**Nombre**: [Task name from summary]
**Estado**: [status] | **Prioridad**: [priority]
**Asignados**: [assignees]

**Descripción del ticket**:
[Resumen breve de lo que el ticket solicita, extraído de la descripción]

**Alcance mencionado en el ticket**:
- [Lista de rutas/módulos mencionados en el ticket]
- Verificar que estos archivos/rutas están modificados en el PR

**Resultado esperado**:
[Lo que el ticket espera como resultado]

**Validación**:
- ✅/❌ El PR implementa el resultado esperado
- ✅/❌ Todas las rutas del alcance están cubiertas
- ✅/❌ La validación maneja el caso descrito
- ⚠️ Observaciones adicionales o gaps detectados
```

**If ticket was not found or fetch failed:**
```markdown
### 6. Contexto del Ticket ClickUp
⚠️ **Ticket no encontrado**: No se pudo obtener la información del ticket CU-XXXXXXXX.
El PR será revisado sin el contexto del ticket.
```

**If no ticket ID was found in branch name or PR description:**
Omit this section entirely from the review.

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
- When ClickUp ticket context is available, explicitly validate that the PR addresses the ticket requirements and expected results.

## Anti-loop guards (hard limits)
- Reading outside the PR diff is allowed **only** in the bounded way described in step 5 (verifying a specific pattern/duplication finding, capped at ~5 extra file reads, targeted grep over browsing). Do not use it as general exploration.
- Do not broaden the task beyond the PR scope.
- Do not repeat the same command or reasoning path.
- PR metadata/diff/comments and the ClickUp ticket summary are fetched **once**, by `scripts/prefetch.sh` in step 1 — reuse the cached files in `$WORKDIR`, never re-fetch them yourself with `gh`/`clickup-cli` directly.
- If the diff is large (>1000 lines), prioritize the files most likely to carry risk for *this* repo — infer from what actually changed and from which loaded instruction files flagged them as sensitive (e.g. auth/security-related code, data access/migration files, public API contracts, infra state) rather than assuming a fixed backend layer like "services/controllers". Explicitly state which files were skipped and why.
- If information is missing, state the limitation instead of guessing.
- Limit every tool call to a maximum of **2 attempts**. On the first failure, print the full output/error and explain why. If it fails a second time, skip it and continue — never retry a third time with a variation.
- Inline comments: max **2 attempts per finding** (handled by `post_review.sh`). After that, fall back to a general comment and move on.
- ClickUp ticket fetch: max **2 attempts**. After that, note the failure and proceed without ClickUp context.
- **CI mode never blocks on a question.** If at any point the instructions below seem to require waiting for a human, prefer the CI-mode default (see `MODE=` from step 1) over stalling.
- Global budget: if you notice you are repeating the same class of action (e.g. retrying inline comments) more than ~5 times across the whole run, stop attempting inline comments entirely, note it in the summary comment, and finish.
- **Never make one `Bash` tool call per finding to build `findings.jsonl`** (or for any similarly repetitive bookkeeping) — batch it into a single call once analysis is done. Turns are a hard budget; spending them one-per-finding on a large PR can exhaust it before step 6 (posting) is ever reached, which means *no* comment gets posted at all, not even the general summary.
- **`post_review.sh` always posts the general summary before attempting inline comments.** If turns run short, a posted summary with no inline comments is still a successful run.
- **Always run step 7 (cleanup)** before ending, regardless of how the run went — emptying the working files is not optional, even on early exit/error paths.
- **Step 1 (`scripts/prefetch.sh`) is mandatory and must always run first**, before anything else, in every mode. Never hand-derive `REPO`/`PR`/`WORKDIR`/`SHA`/`TICKET_ID` yourself — the script is the single source of truth and is idempotent, so there is no cost to running it again if you're ever unsure. Guessing or recomputing any of these values by hand is exactly the failure mode this script exists to eliminate.

## Usage examples

**CI (GitHub Actions, env vars already set: `GITHUB_REPOSITORY`, `PR_NUMBER`, `GITHUB_BASE_REF`, `CI=true`, `CLICKUP_TOKEN`, `CLICKUP_TEAM_ID`):**

Run the agent in non-interactive/print mode with the skill's SKILL.md as input. The exact command depends on the agent being used. The agent needs access to `git`, `gh`, `jq`, `clickup-cli`, `ls`, `cat`, `find`, `grep`, `head`, `mkdir`, `tr`, `echo`, `bash`, `Read`, and `Write` tools.

Example (generic):
```bash
<agent-cli> --print --max-turns 40 < SKILL.md
```

**CI, recommended:** the pipeline can optionally call `scripts/prefetch.sh --repo "$GITHUB_REPOSITORY" --pr "$PR_NUMBER"` itself before invoking the agent, purely to fail the job fast on a fetch error outside the agent's turn budget. Either way, the agent will run (or re-run, harmlessly) the same script as its first action in step 1 — there's no separate "fast path" prompt wiring needed anymore, since the script is bundled with the skill and idempotent by design. This is the intended integration for pipelines using models less reliable at following plain prose instructions (e.g. non-Claude models behind a relay) — it removes an entire class of hallucinated/invented context values and cuts token usage.

**Interactive:**
- User: "Review PR myorg/myrepo#42"
- User: "Review https://github.com/myorg/myrepo/pull/42"
- User: "Review the current PR (assumes `gh pr view` works on the checked-out branch)"
