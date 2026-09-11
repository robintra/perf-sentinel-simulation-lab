"""Check the AlertmanagerConfig CRD against what the example file claims of it.

The bearer credential is written into an AlertmanagerConfig, whose schema
belongs to prometheus-operator and not to perf-sentinel. The example states as
fact that this CRD carries no field for an arbitrary header and does carry a
bearer token, which is an assertion about a third-party operator shipped to
users. Nothing else checks it, and if the operator ever grows a header field
the rationale in that file needs rewriting rather than quietly aging.

Usage: check_crd_fields.py <crd.json>
"""
import json
import sys

BASE = ["spec", "receivers", "webhookConfigs", "httpConfig"]

crd = json.load(open(sys.argv[1]))
versions = {v["name"]: v for v in crd["spec"]["versions"]}
version = versions.get("v1alpha1") or next(iter(versions.values()))
schema = version["schema"]["openAPIV3Schema"]


def walk(node, path):
    for key in path:
        node = node.get("properties", {}).get(key)
        if node is None:
            return None
        while node.get("type") == "array":
            node = node["items"]
    return node


http_config = walk(schema, BASE)
if http_config is None:
    sys.exit("no spec.receivers.webhookConfigs.httpConfig in the schema")

fields = sorted(http_config.get("properties", {}))
for leaf in ("name", "key"):
    if walk(schema, BASE + ["authorization", "credentials", leaf]) is None:
        sys.exit("httpConfig.authorization.credentials.%s is absent" % leaf)

# `proxyConnectHeader` is not a counter-example. It sets headers on the CONNECT
# request to a proxy, never on the webhook request itself, so it cannot carry a
# credential to the receiver. Anything else with "header" in its name would be,
# and would mean the example file's rationale for bearer has to be rewritten
# rather than left to age quietly.
PROXY_ONLY = {"proxyConnectHeader"}
header_like = [f for f in fields if "header" in f.lower() and f not in PROXY_ONLY]
if header_like:
    sys.exit("the CRD DOES carry a request-header field now (%s): the example "
             "file's rationale for bearer needs rewriting" % ", ".join(header_like))

print("httpConfig fields: %s. authorization.credentials.{name,key} present, and "
      "the only header field is proxyConnectHeader, which reaches the proxy and "
      "never the receiver" % ", ".join(fields))
