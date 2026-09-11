"""Assert the VictoriaMetrics twin is written in VictoriaMetrics' own spelling.

No VM operator runs in this lab, so no schema admits this file. What actually
goes wrong on a hand-maintained twin is not a missing field, it is a camelCase
key carried across from the prometheus-operator file: VM spells its receiver
config in snake_case, and an unknown key is dropped without a word.

Usage: check_vm_spelling.py <incident-alerts-victoriametrics-operator.yaml>
"""
import sys

import yaml

# Spellings that belong to the prometheus-operator twin and must never appear.
CAMEL_STRAYS = ("sendResolved", "maxAlerts", "httpConfig", "webhookConfigs",
                "bearerTokenSecret", "groupWait", "groupInterval", "repeatInterval")

raw = open(sys.argv[1]).read()
docs = [d for d in yaml.safe_load_all(raw) if d]
amc = next((d for d in docs if d.get("kind") == "VMAlertmanagerConfig"), None)
if amc is None:
    sys.exit("no VMAlertmanagerConfig document")

route = amc["spec"]["route"]
webhook = amc["spec"]["receivers"][0]["webhook_configs"][0]
bearer = webhook.get("http_config", {}).get("bearer_token_secret", {})

checks = {
    "apiVersion is VM's": str(amc.get("apiVersion", "")).startswith(
        "operator.victoriametrics.com/"),
    "send_resolved": webhook.get("send_resolved") is True,
    "max_alerts": webhook.get("max_alerts") == 1000,
    "url ends in /api/incidents": str(webhook.get("url", "")).endswith("/api/incidents"),
    "http_config.bearer_token_secret.name": bool(bearer.get("name")),
    "http_config.bearer_token_secret.key": bool(bearer.get("key")),
    "route.group_by": isinstance(route.get("group_by"), list),
    "route.group_wait": bool(route.get("group_wait")),
    "route.group_interval": bool(route.get("group_interval")),
    "route.repeat_interval": bool(route.get("repeat_interval")),
    # disableNamespaceMatcher is a VMAlertmanager field, never one of this
    # resource. What this file owes its reader is naming the trap, which is the
    # likeliest reason a correct receiver posts nothing at all.
    "documents the namespace-matcher trap": "disableNamespaceMatcher" in raw,
}

bad = [name for name, good in checks.items() if not good]
if bad:
    sys.exit("wrong or missing: %s" % "; ".join(bad))

strays = [key for key in CAMEL_STRAYS if key in raw]
if strays:
    sys.exit("prometheus-operator spellings leaked in: %s" % ", ".join(strays))

print("%d receiver and route fields correct, no camelCase key carried over"
      % len(checks))
