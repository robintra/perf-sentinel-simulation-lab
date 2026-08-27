# diff-mutated-findings

Template-mutation pairing in `diff`, and what it deliberately does not do.

## Why it exists

A finding's identity ends with the hash of its normalized template. Add a
predicate to a query and the identity moves, so before 0.15.0 a refactor read
as two unrelated events: the old finding appeared under *resolved* and a brand
new one under *new*. Both readings were wrong in the same breath. The
anti-pattern was still live, yet the report said it had been fixed, and a CI
gate keyed on `new_findings` fired for a problem that predated the change.

Since 0.15.0 `diff` pairs the two sides into `mutated_findings` when the
detector, service, endpoint and grouping all match and only the template moved.
The pair is counted as neither new nor resolved.

Two properties matter as much as the pairing itself, and both are gated here.

**A mutation must never be guessed.** An identity is also the acknowledgment
boundary, so a wrong merge would silence a genuinely new problem. When the
sides are not one-to-one, the pairing falls back to the finding's code anchor,
the `(filepath, function)` pair the OTel `code.*` attributes carry, and it
pairs only when that anchor is itself unambiguous.

**A severity escalation hidden inside a mutation must stay visible.** The pair
never reaches `severity_changes`, so the mutated line is its only witness. A
`WARNING → CRITICAL` that rendered as a plain neutral line would be a
regression the report shows and nobody sees.

## Fixtures

Trace files, not reports. Each pair is a real analysis run, so the templates
below are what the tokenizer actually produces.

| Pair | Shape | Expected |
| --- | --- | --- |
| `before` / `after` | one N+1 SQL, the query gains `AND quantity > ?` | 0 new, 0 resolved, **1 mutated** |
| `escalation-before` / `escalation-after` | one N+1 HTTP, the path gains a segment and the call count crosses the severity ceiling (8 calls warning, 12 critical) | 1 mutated, `warning → critical`, `severity_changes` empty |
| `ambiguous-before` / `ambiguous-after` | one resolved, two successors, **all under one code anchor** | 2 new, 1 resolved, **0 mutated** |
| `anchored-before` / `anchored-after` | one resolved, two successors, in **different functions** | 1 new, 0 resolved, **1 mutated** |

The last two are the same 1-versus-2 shape on purpose. Only the anchor differs,
and it is what decides whether pairing is honest or a guess.

## Sub-tests

1. **A mutation pairs** and consumes both sides.
2. **SARIF stays clean.** A mutation is neither new nor resolved, so it raises
   no code-scanning alert. Asserted as a deliberate absence, so a later change
   that starts emitting one is caught rather than welcomed.
3. **The dashboard carries the pair**, in the embedded payload, in the Diff
   panel's table, and in the CSV export's `before_template` column.
4. **The escalation is visible** on the pair, in the JSON and rendered as
   `WARNING→CRITICAL` in the text output, with `severity_changes` empty.
5. **Ambiguity is never guessed**, and a distinct code anchor resolves it when
   it legitimately can.

## Running it

```bash
make verify-diff-mutated-findings
```

Hermetic: the binary under validation runs over the committed fixtures, no
cluster and no daemon contact.
