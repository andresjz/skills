# Notas: determinismo en `review-pr-clickup`

Este documento resume el problema que se ha estado solucionando en este skill, los cambios aplicados hasta ahora (todavía no commiteados/publicados), y una sugerencia para el siguiente paso dado que la última solución no parece funcionar de forma confiable en producción.

## Contexto del problema

El skill corre en GitHub Actions usando un modelo **distinto a Claude** (`zai.glm-4.7`) servido vía un relay. Estos modelos son menos confiables siguiendo prosa/instrucciones al pie de la letra que Claude, lo que produce dos síntomas recurrentes:

1. **No determinismo**: el modelo a veces inventa/asume valores en vez de ejecutar los comandos exactos indicados.
2. **Alucinación**: en pasos que requieren cálculo exacto (rutas, números de línea), el modelo "adivina" en vez de verificar.

## Síntomas concretos encontrados en runs reales (en orden cronológico)

1. **Resolución de contexto no determinista** (`REPO`/`PR`/`WORKDIR` recalculados a mano por el modelo, con drift).
2. **Confusión de paths**: duplicación de lógica entre bash del workflow y prosa del skill.
3. **Instrucciones del repo no detectadas**: el glob original (`*.instructions.md`) no encontraba archivos planos como `coding-standards.md`.
4. **Instrucciones "no encontradas" aunque el repo ya estaba clonado**: el skill leía `.github/instructions/` con un path relativo, dependiente del `cwd` de la sesión — no garantizado que fuera la raíz del repo.
5. **Comentarios inline fallando con `could not be resolved`**: el modelo usaba el número de línea que el tool `Read` muestra al ver `diff.txt` (un solo archivo grande que concatena el diff de todos los archivos del PR) como si fuera el número de línea real del archivo comentado — son escalas completamente distintas.
6. **Cero comentarios publicados en una corrida real**: al pedirle al modelo que escribiera cada hallazgo con una llamada `Bash` separada (`cat >>` por finding), se agotó el presupuesto de turnos (`--max-turns 40`) antes de llegar al paso de publicación — ni el resumen general ni los comentarios inline se publicaron.

## Cambios aplicados hasta ahora (sin commitear/publicar todavía)

Todo esto vive localmente en `skills/review-pr-clickup/SKILL.md` y `scripts/prefetch.sh` (versión en `metadata.version` sigue en `1.0.3`, sin bump hasta que se confirme y publique):

- **`scripts/prefetch.sh`** como única fuente de verdad para `REPO`/`PR`/`WORKDIR`/`SHA`/`TICKET_ID`/`REPO_ROOT`, idempotente, en vez de que el modelo recalcule estos valores a mano.
- **`REPO_ROOT`** expuesto por el script y anclado explícitamente en toda lectura de archivos del repo (instrucciones en paso 4, lectura de archivos fuera del diff en paso 5) — nunca un path relativo dependiente del `cwd`.
- **Glob de instrucciones ampliado** (`*.md` en vez de solo `*.instructions.md`) con un Tier 2 de fallback más permisivo para archivos sin frontmatter.
- **`findings.jsonl`**: los hallazgos que ameritan comentario inline se resuelven contra el archivo real vía `grep -n -F "<snippet>" "$REPO_ROOT/<path>"`, nunca contando líneas dentro de `diff.txt`.
- **Batching de la escritura**: `findings.jsonl` se escribe en una sola llamada `Bash` (todos los hallazgos juntos), no una llamada por hallazgo, para no agotar el presupuesto de turnos.
- **Orden de prioridad en el paso 6**: publicar primero el resumen general (Opción A) y solo después intentar los comentarios inline (Opción B), para que un presupuesto de turnos corto degrade a "resumen publicado, sin inline" en vez de "nada publicado".

## Estado actual / riesgo conocido

A pesar de las correcciones anteriores, una corrida real reciente mostró que **no se publicó ningún comentario en absoluto**, ni siquiera el resumen general. Esto sugiere que:

- El presupuesto de turnos puede seguir siendo insuficiente para PRs grandes, incluso con el batching aplicado (no confirmado aún en producción con la corrección más reciente).
- El modelo (`zai.glm-4.7` vía relay) no sigue instrucciones de prosa tan literalmente como Claude — cada nueva capa de instrucciones ("hazlo así", "no hagas esto otro") añade superficie para que el modelo se desvíe, y seguimos encontrando nuevas variantes del mismo problema raíz cada vez que se prueba con un PR real distinto.

Este patrón — cada fix soluciona el síntoma específico observado, pero aparece un síntoma nuevo en la siguiente corrida real — sugiere que **seguir agregando prosa/reglas al skill tiene rendimientos decrecientes** con este modelo.

## Sugerencia: mover la lógica de posting a un script

Dado lo anterior, en vez de seguir refinando instrucciones en prosa para que el modelo ejecute correctamente una secuencia larga de pasos (verificar línea con `grep`, batchear la escritura, priorizar el orden de publicación, reintentar con backoff), se sugiere el mismo patrón ya usado para `prefetch.sh`: **mover todo lo mecánico a un script determinista**, y reducir la responsabilidad del modelo al mínimo posible (juicio, no ejecución).

Propuesta concreta:

1. El modelo solo genera un archivo de "hallazgos crudos" (una escritura, formato simple): por cada finding, `path` + un snippet de código distintivo (no un número de línea) + `tag` + el cuerpo del comentario. El modelo nunca calcula números de línea ni arma el JSON de la API.
2. Un script nuevo (p. ej. `scripts/post_review.sh`, o una extensión de `prefetch.sh`) recibe ese archivo y, de forma 100% mecánica:
   - Resuelve el número de línea real de cada finding con `grep -n -F` sobre `$REPO_ROOT/<path>` (determinista, sin margen de alucinación).
   - Construye el payload JSON de cada comentario.
   - Publica primero el resumen general (`gh pr comment`), y solo después cada comentario inline (`gh api .../pulls/.../comments`), aplicando el límite de 2 intentos por finding con fallback al comentario general si el inline falla.
   - Al final, reporta cuántos comentarios se publicaron exitosamente (para que quede en el log de CI, no solo en el razonamiento del modelo).
3. El modelo pasa a ser responsable únicamente de: identificar el hallazgo, elegir un snippet de código que lo ubique sin ambigüedad, y redactar el texto del comentario — nunca de la mecánica de publicación.

Esto es consistente con el principio que ya guía el resto del skill (mover lo 100% mecánico fuera de la prosa) y elimina de raíz la clase de error de "número de línea equivocado" y "se acabaron los turnos antes de publicar", en vez de seguir parchando síntomas uno por uno.

## Implementación completada (v1.1.0)

Se implementaron dos scripts:

1. **`scripts/post_review.sh`**: recibe `findings.jsonl` (con `snippet` en vez de `line`), resuelve números de línea mecánicamente con `grep -n -F` (con fallback progresivo: exacto → 40 chars → 20 chars → fuzzy nearby), publica el resumen y los inline comments, reintenta 1 vez por finding, y cae a comentario general si falla. Reporte final parseable.

2. **`scripts/analyze_trace.sh`**: analiza el trace JSONL de `claude code --debug` y produce un summary estructurado (turns, costo, errores por paso, tool usage). Para debugging post-mortem de corridas fallidas.

## Qué cambió en SKILL.md vs la versión anterior

| Aspecto | Antes (prosa) | Ahora (script) |
|---|---|---|
| **Resolución de línea** | Modelo ejecuta `grep -n -F` manual y escribe `line` en findings.jsonl | Modelo escribe `snippet`, el script resuelve la línea |
| **Payload JSON** | Modelo construye con `jq` o `cat`, propenso a errores (tag, null, etc.) | Script construye payload correcto siempre |
| **Posteo inline** | 4 bloques de bash + reglas de retry en prosa | Una llamada a `scripts/post_review.sh` |
| **Suggestion multi-line** | `start_line` en JSON, modelo debe calcularlo | `start_snippet` opcional, script calcula el rango |
| **Trace/debug** | No existía | `scripts/analyze_trace.sh` para diagnosticar corridas |

## Estado: pendiente de probar en producción

- Los scripts están escritos y commiteados en `skills/review-pr-clickup/` y copiados a `~/.agents/skills/review-pr-clickup/`.
- Falta probar con un PR real para verificar que `post_review.sh` resuelve correctamente los snippets y que `analyze_trace.sh` produce output útil.
