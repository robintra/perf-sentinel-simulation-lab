"""Take the shipped AlertmanagerConfig and point it at this lab's two daemons.

Three substitutions, and no more. Two are addresses: the lab calls its Service
perf-sentinel-daemon and exposes it on 14318, where the example writes a
generic `perf-sentinel` on 4318. The third appends the 0.21.0 twin to the same
receiver, so one Alertmanager notification, one startsAt and one credential
reach both binaries at the same millisecond, and the only difference left
between them is the image.

Everything else, the httpConfig bearer block above all, is applied untouched.

Usage: build_receiver.py <source.yaml> <destination.yaml> <url> <twin url>
"""
import copy
import sys

import yaml

src, dst, url, twin_url = sys.argv[1:5]
doc = next(d for d in yaml.safe_load_all(open(src))
           if d and d.get("kind") == "AlertmanagerConfig")

webhooks = doc["spec"]["receivers"][0]["webhookConfigs"]
if len(webhooks) != 1:
    sys.exit("expected exactly one webhookConfig, found %d" % len(webhooks))

original = webhooks[0]["url"]
webhooks[0]["url"] = url
twin = copy.deepcopy(webhooks[0])
twin["url"] = twin_url
webhooks.append(twin)

# The credential block is the point of the whole scenario. If a future edit
# ever drops it, the delivery would succeed for the wrong reason.
if "authorization" not in webhooks[0].get("httpConfig", {}):
    sys.exit("the shipped receiver no longer carries httpConfig.authorization")

yaml.safe_dump(doc, open(dst, "w"), sort_keys=False)
print("url %s -> %s, twin %s" % (original, url, twin_url))
