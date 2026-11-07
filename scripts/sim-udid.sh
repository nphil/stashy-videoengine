#!/usr/bin/env bash
# Prints the UDID of an iPhone simulator the runner already created, newest
# iOS runtime first; its name and runtime go to stderr. Pre-created devices
# are known to pair with their runtime, whereas pairing an arbitrary device
# type with the newest runtime can fail with SimError 403 "Incompatible
# device".
set -euo pipefail

xcrun simctl list devices available -j | python3 -c '
import json, re, sys

devices = json.load(sys.stdin)["devices"]

def ios_version(runtime):
    m = re.search(r"\.iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else None

for runtime in sorted((r for r in devices if ios_version(r)), key=ios_version, reverse=True):
    for dev in devices[runtime]:
        if dev.get("isAvailable") and dev.get("name", "").startswith("iPhone"):
            print(dev["udid"])
            print("simulator: %s (%s)" % (dev["name"], runtime.rsplit(".", 1)[-1]), file=sys.stderr)
            sys.exit(0)
sys.exit("no available iPhone simulator")
'
