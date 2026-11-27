#!/usr/bin/env bash
#
# check-template-values.sh - keep the generation-inputs snapshot in sync.
#
# `post-generate.rhai` writes `.cargo-generate/values.toml` in every generated
# project so `make template-update` can re-render the template with the original
# answers. cargo-generate's Rhai API has no variable enumeration, so the hook
# carries an explicit placeholder list; this script is the guard that keeps that
# list identical to `cargo-generate.toml`.
#
# Checks:
#   1. every placeholder declared in `cargo-generate.toml` (top-level and inside
#      any `[conditional.*.placeholders]` section) appears in the hook list,
#      with no extras and no duplicates, in the same order;
#   2. the hook's TEMPLATE_VALUES_VERSION equals `[template] version`;
#   3. the hook writes `.cargo-generate/values.toml`;
#   4. `.cargo-generate/.gitkeep` exists (it creates the directory the hook
#      writes into, because Rhai's file module cannot create directories).
#
# Usage:
#   scripts/check-template-values.sh          # verify (CI + pre-commit)
#   scripts/check-template-values.sh --fix    # rewrite the hook list/version
#
# Requires: bash, python3. Template-only; not shipped to generated projects.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$SCRIPT_DIR")"
MODE="${1:-}"

if [[ -n "$MODE" && "$MODE" != "--fix" ]]; then
	echo "Usage: $(basename "$0") [--fix]" >&2
	exit 2
fi

exec python3 - "$ROOT" "$MODE" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
fix = sys.argv[2] == "--fix"

cfg_path = root / "cargo-generate.toml"
hook_path = root / "post-generate.rhai"
keep_path = root / ".cargo-generate" / ".gitkeep"
values_rel = ".cargo-generate/values.toml"

START = "// BEGIN TEMPLATE VALUES PLACEHOLDERS"
END = "// END TEMPLATE VALUES PLACEHOLDERS"


def fail(message: str) -> None:
    print(f"✗ {message}", file=sys.stderr)
    sys.exit(1)


def warn(message: str) -> None:
    print(f"⚠  {message}", file=sys.stderr)


cfg = cfg_path.read_text(encoding="utf-8")
hook = hook_path.read_text(encoding="utf-8")

# 1. Placeholders declared in cargo-generate.toml, in file order. Placeholder
#    definitions are single-line tables that start at column 0 in both the
#    top-level [placeholders] section and every conditional block.
placeholders: list[str] = []
for match in re.finditer(r"(?m)^([a-z][a-z0-9_]*)[ \t]*=[ \t]*\{[ \t]*prompt", cfg):
    name = match.group(1)
    if name not in placeholders:
        placeholders.append(name)

template_section = re.search(r"(?ms)^\[template\][ \t]*$(.*?)(?=^\[|\Z)", cfg)
template_version = None
if template_section:
    version_match = re.search(r'(?m)^version[ \t]*=[ \t]*"([^"]*)"', template_section.group(1))
    if version_match:
        template_version = version_match.group(1)

if not placeholders:
    fail("no placeholders found in cargo-generate.toml")
if template_version is None:
    fail("[template] version not found in cargo-generate.toml")

block_re = re.compile(
    rf"({re.escape(START)}\n)(.*?)({re.escape(END)})", re.DOTALL
)
block_match = block_re.search(hook)
if not block_match:
    fail(f"placeholder block markers not found in post-generate.rhai ({START} … {END})")

hook_names = re.findall(r'"([a-z0-9_]+)"', block_match.group(2))
version_match = re.search(r'(?m)^const TEMPLATE_VALUES_VERSION = "([^"]*)";', hook)
hook_version = version_match.group(1) if version_match else None

service_cfg_path = root / "service-template" / "cargo-generate.toml"
service_cfg = service_cfg_path.read_text(encoding="utf-8") if service_cfg_path.is_file() else ""
service_section = re.search(r"(?ms)^\[template\][ \t]*$(.*?)(?=^\[|\Z)", service_cfg)
service_version = None
if service_section:
    service_version_match = re.search(
        r'(?m)^version[ \t]*=[ \t]*"([^"]*)"', service_section.group(1)
    )
    if service_version_match:
        service_version = service_version_match.group(1)

problems: list[str] = []

missing = [name for name in placeholders if name not in hook_names]
extra = [name for name in hook_names if name not in placeholders]
duplicates = sorted({name for name in hook_names if hook_names.count(name) > 1})

if missing:
    problems.append("hook list is missing: " + ", ".join(missing))
if extra:
    problems.append("hook list has unknown placeholders: " + ", ".join(extra))
if duplicates:
    problems.append("hook list has duplicates: " + ", ".join(duplicates))
if not missing and not extra and not duplicates and hook_names != placeholders:
    first = next(
        i for i, (a, b) in enumerate(zip(hook_names, placeholders)) if a != b
    )
    problems.append(
        f"hook list order differs from cargo-generate.toml at index {first} "
        f"(hook: {hook_names[first]}, config: {placeholders[first]})"
    )
if hook_version is None:
    problems.append("TEMPLATE_VALUES_VERSION not found in post-generate.rhai")
elif hook_version != template_version:
    problems.append(
        f"TEMPLATE_VALUES_VERSION ({hook_version}) does not match "
        f"[template] version ({template_version}) in cargo-generate.toml"
    )
if not service_cfg_path.is_file():
    problems.append("service-template/cargo-generate.toml is missing")
elif service_version is None:
    problems.append("service-template/cargo-generate.toml has no [template] version")
elif service_version != template_version:
    problems.append(
        f"service-template version ({service_version}) does not match "
        f"[template] version ({template_version}) in cargo-generate.toml"
    )
if f'"{values_rel}"' not in hook:
    problems.append(f'post-generate.rhai does not write "{values_rel}"')
if not keep_path.is_file():
    problems.append(
        ".cargo-generate/.gitkeep is missing (it creates the snapshot directory; "
        "the Rhai hook cannot mkdir)"
    )

if problems and not fix:
    for problem in problems:
        print(f"✗ {problem}", file=sys.stderr)
    print(
        "\nFix the hook by hand, or regenerate the list with:\n"
        "  scripts/check-template-values.sh --fix",
        file=sys.stderr,
    )
    sys.exit(1)

if problems and fix:
    # Rewrite the list and the version constant, leaving everything else alone.
    new_block = "const TEMPLATE_VALUES_PLACEHOLDERS = [\n" + "".join(
        f'    "{name}",\n' for name in placeholders
    ) + "];\n"
    hook = hook[: block_match.start(2)] + new_block + hook[block_match.end(2):]

    if version_match:
        hook = hook.replace(
            version_match.group(0),
            f'const TEMPLATE_VALUES_VERSION = "{template_version}";',
            1,
        )
    else:
        fail("cannot fix: TEMPLATE_VALUES_VERSION constant not found")
    if f'"{values_rel}"' not in hook:
        fail(f'cannot fix: post-generate.rhai does not write "{values_rel}"')
    if not keep_path.is_file():
        keep_path.parent.mkdir(parents=True, exist_ok=True)
        keep_path.write_text("", encoding="utf-8")

    if service_cfg_path.is_file():
        if service_version is None:
            service_cfg = re.sub(
                r"(?m)^(\[template\][ \t]*$)",
                lambda m: m.group(1) + f'\nversion = "{template_version}"',
                service_cfg,
                count=1,
            )
        else:
            service_cfg = service_cfg.replace(
                f'version = "{service_version}"',
                f'version = "{template_version}"',
                1,
            )
        service_cfg_path.write_text(service_cfg, encoding="utf-8")

    hook_path.write_text(hook, encoding="utf-8")
    for problem in problems:
        print(f"⚙  fixed: {problem}")
    print(f"✓ post-generate.rhai now records all {len(placeholders)} placeholders")
    sys.exit(0)

for name in placeholders:
    if len(name) > 0 and not re.fullmatch(r"[a-z][a-z0-9_]*", name):
        warn(f"unexpected placeholder name: {name}")

print(
    f"✓ generation inputs snapshot: {len(placeholders)} placeholders, "
    f"template version {template_version}"
)
PY
