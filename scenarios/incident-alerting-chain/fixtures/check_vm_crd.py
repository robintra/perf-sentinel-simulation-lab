"""Read what the VictoriaMetrics CRD really says about a webhook's http_config.

The example file and the CHANGELOG both rest on a claim about this schema: that
`http_headers` arrived late, and that an older API server "prunes the block in
silence", leaving the webhook with no credential. That is a statement about a
third-party CRD, shipped to users, and this is the only place it is checked.

Prints one line per version: whether the schema declares its own properties or
preserves unknown fields, and whether `bearer_token_secret` and `http_headers`
are named in it. A schema carrying x-kubernetes-preserve-unknown-fields cannot
prune anything, which changes what the risk actually is.

Usage: check_vm_crd.py <crd.yaml>
"""
import sys

import yaml

PATH = ["spec", "receivers", "webhook_configs", "http_config"]


def walk(node, path):
    for key in path:
        node = node.get("properties", {}).get(key)
        if node is None:
            return None
        while node.get("type") == "array":
            node = node["items"]
    return node


target = None
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "CustomResourceDefinition" \
            and "vmalertmanagerconfig" in doc["metadata"]["name"]:
        target = doc
        break
if target is None:
    sys.exit("no VMAlertmanagerConfig CRD in the bundle")

for version in target["spec"]["versions"]:
    schema = walk(version["schema"]["openAPIV3Schema"], PATH)
    if schema is None:
        print("%s: no %s in the schema" % (version["name"], ".".join(PATH)))
        continue
    props = sorted(schema.get("properties", {}))
    open_schema = bool(schema.get("x-kubernetes-preserve-unknown-fields"))
    print("%s: http_config is %s"
          % (version["name"],
             "an open object (x-kubernetes-preserve-unknown-fields), so the API "
             "server prunes nothing inside it" if open_schema
             else "a closed object declaring %d properties" % len(props)))
    if props:
        print("    declared: %s" % ", ".join(props))
        print("    bearer_token_secret: %s, http_headers: %s"
              % ("yes" if "bearer_token_secret" in props else "no",
                 "yes" if "http_headers" in props else "no"))
