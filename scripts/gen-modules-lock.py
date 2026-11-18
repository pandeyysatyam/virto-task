#!/usr/bin/env python3
"""Generate docker/platform/modules.lock from a Virto bundle manifest.

The bundle manifest (modules.json) only lists module ids and versions.
This script looks each module up in the public Virto module registry
(modules_v3.json) to find its GitHub repository, then writes one line per
module: "<id> <version> <download url>".

Usage:
    python3 scripts/gen-modules-lock.py docker/platform/modules.json > docker/platform/modules.lock
"""
import json
import re
import sys
import urllib.request

REGISTRY_URL = "https://raw.githubusercontent.com/VirtoCommerce/vc-modules/master/modules_v3.json"

# Modules added on top of the official bundle.
# OpenSearch: search provider for Amazon OpenSearch Service on AWS
# (needs platform 3.1073.0 or newer, we run 3.1076.13).
EXTRA_MODULES = [
    {"Id": "VirtoCommerce.OpenSearch", "Version": "3.1005.0"},
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 1

    with open(sys.argv[1], encoding="utf-8") as fh:
        bundle = json.load(fh)

    with urllib.request.urlopen(REGISTRY_URL, timeout=60) as resp:
        registry = {m["Id"]: m for m in json.load(resp)}

    print(f"# Virto Commerce module lock, generated from modules.json "
          f"(bundle {bundle.get('BundleVersion', '?')}) by scripts/gen-modules-lock.py")
    print("# id version url")

    modules = [m for src in bundle["Sources"] for m in src.get("Modules", [])]
    modules += EXTRA_MODULES

    for module in modules:
        mod_id, version = module["Id"], module["Version"]
        entry = registry.get(mod_id)
        if entry is None:
            print(f"module {mod_id} not found in registry", file=sys.stderr)
            return 2
        github_urls = [v["PackageUrl"] for v in entry["Versions"]
                       if "github.com" in v.get("PackageUrl", "")]
        if not github_urls:
            print(f"no GitHub release url for {mod_id}", file=sys.stderr)
            return 2
        repo = re.match(r"https://github.com/VirtoCommerce/([^/]+)/", github_urls[-1]).group(1)
        url = (f"https://github.com/VirtoCommerce/{repo}/releases/download/"
               f"{version}/{mod_id}_{version}.zip")
        print(mod_id, version, url)
    return 0


if __name__ == "__main__":
    sys.exit(main())
