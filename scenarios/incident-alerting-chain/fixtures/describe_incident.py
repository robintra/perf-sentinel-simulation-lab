"""Summarise the richest incident on stdin, for the scenario's report line.

Reads the JSON array GET /api/incidents returns and describes the one that
froze the most findings, because that is the one the assertion is about.

Usage: curl ... | describe_incident.py
"""
import json
import sys

rows = json.load(sys.stdin)
if not rows:
    sys.exit("no incident")
best = max(rows, key=lambda i: len(i.get("findings", [])))
print("%s/%s kind=%s, %d findings frozen over [%d, %d]"
      % (best.get("namespace"), best["service"], best["kind"],
         len(best.get("findings", [])), best["window_from_ms"], best["window_to_ms"]))
