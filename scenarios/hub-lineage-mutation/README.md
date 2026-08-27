# hub-lineage-mutation

When a query's shape changes, the finding is a new one. Its history is not.

## Why it exists

A signature is derived from the normalized SQL template, so adding a predicate
mints a brand-new signature. Read naively that says "the old problem is gone, a
new one appeared", and the age of the real problem resets to zero. The Hub links
the pair instead and carries the **origin's** first sighting, plus a chain
depth, onto the successor.

Nothing had ever driven that path from real traffic. The Hub's tests forge the
templates; the daemon's tests never produce two shapes on one endpoint.

## The fault endpoint

`POST /api/fault/template-mutation-sql?shape=a|b` on `order-service` issues the
same N+1 in two shapes, `b` adding `AND quantity > 0`. Same detector, same
service, same endpoint (the normalizer strips the query string), different
template.

It is a **new, additive** endpoint rather than a parameter on the existing
`n-plus-one-sql`: that endpoint's committed fixtures are pinned to its current
shape, and parameterizing it would have rewritten them.

## Why only the Hub half is isolated

Traffic and detection are real, over the shared daemon. The link is only ever
created on the import that **first** sees the successor signature, so a Hub that
already knows both shapes proves nothing. A fresh namespace gives an empty
database and, just as importantly, control over the import order: the
predecessor must have been observed strictly earlier, not in the same batch.

Its Sources[0] exists only to carry the import key, and its one boot poll fails
against a name that resolves nowhere. Reachability belongs to
[`hub-source-reachability`](../hub-source-reachability).

## What it asserts

1. The two shapes yield two findings on one endpoint, with distinct signatures.
2. The successor reports one predecessor; the predecessor itself reports none.
3. `original_first_seen` is the **predecessor's** first sighting, strictly
   earlier than the successor's own. An origin equal to the successor's own
   first sighting would mean the age reset, which is the defect.
4. `perf-sentinel diff` pairs the same two as a `mutated_findings` entry, not as
   one resolved plus one new.

Leg 4 replays the two shapes as span sets, since `diff` reads traces rather than
reports. Literals are put back where the tokenizer put placeholders: replaying
a normalized template verbatim makes every span identical and the pipeline
reports `redundant_sql` instead of the N+1 the daemon found.
[`diff-mutated-findings`](../diff-mutated-findings) already pins the pairing
rules on hand-written fixtures; what this leg adds is that a **real emitted**
template pair is still what the matcher considers a mutation.

## What the Hub does not expose

The predecessor's signature stays internal. The API publishes the chain as two
numbers, `original_first_seen` and `predecessors`, so those are what the
scenario asserts on.

## Running it

```bash
make verify-hub-lineage-mutation
```

Needs the cluster, `make seed-services`, `make seed-hub-local` and
`make port-forward`.
