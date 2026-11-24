#!/usr/bin/env bash
#
# list-services.sh - list the first service and every added service.
#
# The first service is the workspace root package (it keeps the project slug
# used by the root HelmRelease). Added services are workspace members whose
# manifest lives under services/<slug>/; vendored crates and service-core are
# excluded.
#
# Output: one tab-separated row per service, no header:
#
#   <slug>	<dir>	<package>	<bin>
#
#   slug     canonical kebab-case service name (HelmRelease/image/tag name)
#   dir      "." for the first service, "services/<slug>" for added services
#   package  Cargo package name (may be snake_case)
#   bin      binary target name built for that service
#
# Usage:
#   scripts/list-services.sh                 # all services
#   scripts/list-services.sh --service worker
#   scripts/list-services.sh --json          # JSON array (same fields)
#
# Requires cargo (metadata --no-deps) and python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

FILTER=""
JSON=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--service)
			FILTER="${2:-}"
			shift 2
			;;
		--service=*)
			FILTER="${1#*=}"
			shift
			;;
		--json)
			JSON=true
			shift
			;;
		--help|-h)
			sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			echo "Usage: $0 [--service <slug>] [--json]" >&2
			exit 2
			;;
	esac
done

if [[ ! -f "${PROJECT_ROOT}/Cargo.toml" ]]; then
	echo "Error: ${PROJECT_ROOT}/Cargo.toml not found (list-services.sh runs in a generated project)" >&2
	exit 1
fi

# NOTE: python reads its program from stdin here, so the cargo metadata JSON
# cannot also arrive on stdin (a pipe plus this heredoc would drop it). Run
# cargo from inside python instead.
python3 - "$PROJECT_ROOT" "$FILTER" "$JSON" <<'PY'
import json
import os
import re
import subprocess
import sys

root = os.path.realpath(sys.argv[1])
filter_slug = sys.argv[2].strip().replace("_", "-")
as_json = sys.argv[3].lower() == "true"

try:
    metadata = subprocess.check_output(
        [
            "cargo",
            "metadata",
            "--no-deps",
            "--format-version",
            "1",
            "--manifest-path",
            os.path.join(root, "Cargo.toml"),
        ],
        text=True,
    )
except FileNotFoundError:
    sys.stderr.write("Error: cargo not found on PATH\n")
    sys.exit(1)
except subprocess.CalledProcessError as exc:
    sys.exit(exc.returncode or 1)

data = json.loads(metadata)
workspace_root = os.path.realpath(data.get("workspace_root") or root)
workspace_members = set(data.get("workspace_members") or [])


def helm_slug(directory, fallback):
    """Read the canonical slug from a service HelmRelease, if present."""
    manifest = os.path.join(directory, "deploy", "base", "helmrelease.yaml")
    if not os.path.isfile(manifest):
        return fallback
    try:
        with open(manifest, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return fallback
    match = re.search(
        r"^[ \t]*fullnameOverride:[ \t]*[\"']?([A-Za-z0-9._-]+)", text, re.MULTILINE
    )
    if match:
        return match.group(1).replace("_", "-")
    return fallback


def makefile_slug():
    manifest = os.path.join(root, "Makefile")
    if not os.path.isfile(manifest):
        return None
    try:
        with open(manifest, encoding="utf-8") as handle:
            match = re.search(
                r"^PROJECT_NAME[ \t]*:=[ \t]*([A-Za-z0-9._-]+)",
                handle.read(),
                re.MULTILINE,
            )
    except OSError:
        return None
    return match.group(1).replace("_", "-") if match else None


def binary_name(package):
    for target in package.get("targets") or []:
        if "bin" in (target.get("kind") or []):
            return target.get("name") or package["name"]
    return package["name"]


root_package = None
added = {}

for package in data.get("packages") or []:
    if package.get("id") not in workspace_members:
        continue
    manifest = os.path.realpath(package.get("manifest_path") or "")
    if not manifest:
        continue
    rel_dir = os.path.relpath(os.path.dirname(manifest), workspace_root)
    if rel_dir == ".":
        if root_package is None:
            root_package = package
        continue
    parts = rel_dir.split(os.sep)
    if len(parts) >= 2 and parts[0] == "services":
        slug = parts[1].replace("_", "-")
        added.setdefault(
            slug,
            {
                "slug": slug,
                "dir": os.path.join("services", parts[1]),
                "package": package["name"],
                "bin": binary_name(package),
            },
        )

rows = []

if root_package is not None:
    fallback = makefile_slug() or root_package["name"].replace("_", "-")
    rows.append(
        {
            "slug": helm_slug(root, fallback),
            "dir": ".",
            "package": root_package["name"],
            "bin": binary_name(root_package),
        }
    )
elif filter_slug:
    # No root package: still allow filtering an added service below.
    pass

for slug in sorted(added):
    row = added[slug]
    row["slug"] = helm_slug(os.path.join(root, row["dir"]), row["slug"])
    rows.append(row)

if filter_slug:
    rows = [row for row in rows if row["slug"] == filter_slug]

if as_json:
    json.dump(rows, sys.stdout, indent=2)
    sys.stdout.write("\n")
else:
    for row in rows:
        sys.stdout.write(
            "{slug}\t{dir}\t{package}\t{bin}\n".format(**row)
        )
PY
