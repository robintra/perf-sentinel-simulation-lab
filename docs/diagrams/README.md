# B2 scenario architecture diagrams

Standalone Mermaid sources, one per scenario. The same diagrams are
embedded as fenced code blocks in `../SCENARIOS-B2.md` so the guide
renders self-contained on GitHub. These `.mmd` files are kept separate
so they can be:

- Edited in a Mermaid-aware editor (VS Code Mermaid extension, IntelliJ
  Mermaid plugin, mermaid.live).
- Rendered to SVG/PNG offline for slide decks or external docs.
- Promoted into the upstream perf-sentinel docs at
  `/Users/robintrassard/RustroverProjects/perf-sentinel` without
  carrying the lab's surrounding markdown.

## Files

| File | Scenario |
| --- | --- |
| `b2-1-hybrid-daemon-batch.mmd` | hybrid daemon -> batch HTML |
| `b2-2-batch-tempo-scrape.mmd` | batch over Tempo |
| `b2-3-daemon-otlp-direct.mmd` | daemon OTLP direct (no Collector) |
| `b2-4-multiformat-input.mmd` | multi-format input (Jaeger + Zipkin) |
| `b2-5-calibrate-mode.mmd` | calibrate energy coefficients |
| `b2-6-sidecar-pattern.mmd` | sidecar pattern |
| `b2-7-correlation-finding.mmd` | cross-trace correlation finding |
| `b2-8-pg-stat.mmd` | `report --pg-stat` live integration |

## Render to SVG locally

```bash
npx -y @mermaid-js/mermaid-cli -i b2-1-hybrid-daemon-batch.mmd -o b2-1.svg
```

Or batch:

```bash
for f in *.mmd; do
  npx -y @mermaid-js/mermaid-cli -i "$f" -o "${f%.mmd}.svg"
done
```

## Visual vocabulary

- Solid arrow = always-on flow (production traffic, OTLP, pull loops).
- Dashed arrow = on-demand fetch (CI snapshot, CLI batch, query API).
- Box with double border (`[[ ... ]]`) = perf-sentinel surface (CLI
  subcommand or daemon endpoint).
- Light-blue fill = `classDef sentinel` styling, applied to every
  perf-sentinel node for at-a-glance recognition.
