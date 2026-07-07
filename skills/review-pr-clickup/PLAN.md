# Plan de implementación: scripts deterministas para review-pr-clickup

## Problema

El skill `review-pr-clickup` delega en el modelo (vía prosa en SKILL.md) la construcción manual de payloads JSON para la API de GitHub y la ejecución de comandos `gh`. El modelo (`zai.glm-4.7`) comete errores sistemáticos:

1. Incluye `tag` en el payload (`"tag" is not a permitted key`)
2. Envía `"start_line": null` (`nil is not an integer`)
3. Calcula números de línea incorrectos (usa line numbers de `diff.txt` en vez del archivo real)
4. Gasta turnos en retries fallidos, agotando el budget antes de publicar

## Solución

Dos scripts nuevos, siguiendo el mismo patrón de `prefetch.sh`: mover todo lo mecánico fuera de la prosa y dentro de código determinista.

---

## Script 1: `scripts/post_review.sh`

Postea el resumen general y los inline comments de forma 100% mecánica.

### Input

El modelo escribe `$WORKDIR/findings.jsonl` con snippet en vez de número de línea:

```jsonl
# Single line
{"path":"src/foo.ts","snippet":"onPress={handleDismissDropdown}","tag":"BUG","body":"[BUG] ..."}

# Multi-line suggestion (start_snippet + snippet = rango)
{"path":"src/bar.ts","start_snippet":"if (user == null) {","snippet":"    return Optional.empty();","tag":"BUG","body":"[BUG] ...```suggestion\n...\n```"}
```

- `snippet`: substring distintivo de la **última línea** del hallazgo (obligatorio)
- `start_snippet`: substring distintivo de la **primera línea** del rango (opcional — multi-line)
- `tag`: metadata para el modelo, el script la elimina del payload
- `body`: texto completo del comentario (puede incluir suggestion fence)
- `path`: relativo al repo, ej. `src/features/vehicle-search/index.tsx`

### Resolución de línea (determinista)

Para cada snippet (lo mismo para `start_snippet` y `snippet`):

1. `grep -n -F "$snippet" "$REPO_ROOT/$path"` — exacto, fixed string
2. Si 0 matches → probar con primeros 40 caracteres
3. Si 0 matches → probar con primeros 20 caracteres
4. Si ≠ 1 match en cualquier paso → fuzzy nearby search:
   - Buscar con 20 chars, filtrar matches dentro de ±10 líneas del primer match
   - Si exactamente 1 en ese rango → usar esa línea
5. Si todo falla → fallback a comentario general

El script aborta si `start_snippet` se resuelve a una línea >= `snippet` (rango invertido).

### Posting

```bash
# 1. Postear resumen general
gh pr comment "$PR" --repo "$REPO" --body-file "$WORKDIR/summary.md"

# 2. Por cada finding resuelto
for finding in findings_resueltos; do
  # Construir payload: body + path + line + commit_id + side
  # Si start_snippet presente: agregar start_line + start_side
  # NUNCA incluir tag, start_snippet, snippet
  gh api POST "/repos/$REPO/pulls/$PR/comments" --input "$payload_file"
  if falló; then
    reintentar 1 vez
    si sigue fallando → marcar como fallback
  fi
done

# 3. Si hay fallbacks, actualizar el summary comment
if fallbacks > 0; then
  # Postear un segundo comment general con los fallbacks
  gh pr comment "$PR" --repo "$REPO" --body-file "$WORKDIR/summary_fallbacks.md"
fi

# 4. Reporte final a stdout (parseable)
echo "POST_REVIEW_RESULT=summary=ok inline=3 fallback=1 errors=0"
```

### Casos borde

| Situación | Comportamiento |
|---|---|
| `grep` matches 0 | 40 chars → 20 chars → fuzzy nearby → fallback |
| `grep` matches ≥2 | fuzzy nearby (±10 líneas del hunk) → fallback |
| `start_snippet` ≥ `snippet` | fallback (rango invertido) |
| GitHub 422 (bad payload) | retry 1x sin `start_line`/`start_side` → fallback |
| GitHub 404 (line not in diff) | fallback — línea existe en el archivo pero no en este PR |
| `gh pr comment` falla | retry 1x con body simplificado (sin suggestion fences) |
| Snippet tiene caracteres especiales | `grep -F` evita problemas de regex |
| Body contiene $VAR o backticks | jq escapa todo correctamente |

---

## Script 2: `scripts/analyze_trace.sh`

Analiza el trace JSONL generado por `claude code --debug` para diagnosticar qué pasó en una corrida.

### Input

Cada línea del trace es uno de estos tipos:

```
{"type":"assistant","message":{"id":"msg_...","role":"assistant","content":[...],"model":"zai.glm-4.7","stop_reason":null, ...},"session_id":"...","uuid":"..."}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"...","type":"tool_result","content":"...","is_error":false}]},"session_id":"...","uuid":"...","timestamp":"...","tool_use_result":{...}}
{"type":"result","subtype":"error_max_turns","duration_ms":581564,"total_cost_usd":13.19,"num_turns":41,"stop_reason":"tool_use","session_id":"...","errors":["Reached maximum turns (40)"]}
```

### Procesamiento

1. Leer stdin o `--input FILE`, filtrar solo líneas JSON válidas
2. Agrupar por `session_id`
3. Por sesión:
   - Extraer modelo del primer assistant
   - Contar asistentes (turns)
   - Identificar tool_use calls y sus resultados
   - Detectar errores: `is_error: true`, `returnCodeInterpretation` no vacío, `exit code N`
   - Extraer result final: duración, costo, stop_reason, errors
4. Agrupar tool calls en pasos (heuristic):
   - `gh pr view|diff|comment` → "gh fetch/post"
   - `grep -n -F` → "line resolution"
   - `jq` → "json construction"
   - `clickup-cli` → "clickup fetch"
   - `bash scripts/` → "script execution"
   - resto → "misc"

### Output

```
=== Session: 82b3c135-9d63-4be3-bfc5-63086fb10e5b ====================================
Model:      zai.glm-4.7
Turns used: 41 / 40 (BUDGET EXCEEDED)
Duration:   581s | Cost: $13.19
Stop:       tool_use (max_turns)
Exit:       error

=== Tool Calls by Step ===
Step               Calls   Errors   Detail
prefetch           3       0        gh pr view, gh pr diff, gh pr view --json files
findings generation 8       0        2 findings escritos
post summary        1       0        gh pr comment OK
post inline         2       2        gh api POST (422) + bash syntax error
cleanup             1       0

=== Errors ===
1. [Turn 22] gh api POST /repos/ahurisoftware/UTEM-MOBILE/pulls/62/comments
   Exit: 1 | Stderr: "tag" is not a permitted key, "start_line": nil is not an integer
   Resolution: Script post_review.sh strips tag, omits null start_line
2. [Turn 28] bash heredoc syntax
   Exit: 2 | Stderr: syntax error: unexpected end of file
   Resolution: post_review.sh no usa heredocs para JSON; usa jq

=== Tool Usage Summary ===
gh pr view        : 2 calls
gh pr diff        : 1 call
gh pr comment     : 1 call
gh api POST       : 2 calls (1 error)
grep -n -F        : 2 calls
jq                : 3 calls
cat               : 3 calls
bash              : 1 call (1 error)
```

### Modos de uso

```bash
# Post-hoc
bash analyze_trace.sh --input /var/log/trace_2026-07-07.jsonl

# Pipe desde relay (CI)
<agent-cmd> 2>&1 | tee /tmp/raw.log | grep '^{' > /tmp/trace.jsonl
bash analyze_trace.sh --input /tmp/trace.jsonl
```

---

## Cambios en SKILL.md

### Paso 5 (antes — escritura de findings)

**Eliminar** todo el bloque sobre:
- Cálculo manual de line numbers
- Warnings sobre diff.txt offsets
- `grep -n -F` para resolver líneas (ahora lo hace el script)
- Batching de escritura (sigue aplicando, pero formato cambia)

**Reemplazar** con:

```bash
cat > "$WORKDIR/findings.jsonl" << 'EOF'
{"path":"<archivo>","snippet":"<substring exacto de la línea>","tag":"BUG","body":"<completo>"}
EOF
```

Reglas para el modelo:
- El snippet debe ser el substring **más distintivo** de la línea comentada
- Para multi-line suggestion, agregar `start_snippet` con el substring de la primera línea del rango
- Si el snippet se repite en el archivo (>1 match), el script hará fuzzy matching; mejor elegir uno más único
- No usar nombres de función genéricos (`handleClick`, `validate`) sin contexto que los haga únicos
- El número de línea se resuelve automáticamente — no incluirlo

### Paso 6 (antes — posting)

**Eliminar** todo el bloque:
- Option A/B/C
- Templates JSON de inline comments
- Reglas de retry
- Límite de 2 intentos
- Fallback a comentario general

**Reemplazar** con:

```bash
bash "$(dirname "$0")/../scripts/post_review.sh"
```

Explicación breve:
- Postea el resumen general + inline comments
- Si falla un inline, reintenta 1 vez, luego lo agrega al resumen
- Reporta resultado al final

### Métodos de pago (versión)

`metadata.version`: `1.0.5` → `1.1.0`

---

## Orden de implementación

1. Escribir `scripts/post_review.sh` (~180 líneas)
2. Escribir `scripts/analyze_trace.sh` (~140 líneas)
3. Modificar `SKILL.md`: paso 5 y paso 6
4. Copiar a `~/.agents/skills/review-pr-clickup/`
5. Actualizar `DETERMINISM-NOTES.md` con resultado
6. Bump version y commitear
