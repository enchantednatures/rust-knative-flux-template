#!/usr/bin/env bash
#
# test-template-values.sh - end-to-end tests for the generation-inputs snapshot
# (`.cargo-generate/values.toml`) and `scripts/update-from-template.sh`.
#
# Covers:
#   1. generation records the snapshot and removes the `.gitkeep` placeholder;
#   2. re-generating from the snapshot reproduces the tree byte-for-byte;
#   3. `add-service` records a per-service snapshot that re-renders identically;
#   4. `update-from-template.sh` merges an upstream change, keeps local edits,
#      refreshes the snapshot, preserves the crate name (the `--name` input,
#      which is not the `project_name` answer), survives overlay registration
#      lines added by `add-service`, and reports genuine conflicts;
#   5. a service-only update reports "already up to date" when the service
#      template did not change.
#
# Usage:
#   bash scripts/test-template-values.sh
#
# Environment:
#   WORKDIR          Fixture directory (default: mktemp under /tmp)
#   KEEP_WORKDIR=1   Keep the fixture directory after the run
#   TEMPLATE_PATH    Template root under test (default: this repository)
#
# Requires: bash, git, cargo-generate >= 0.23, python3, yq v4 (service part),
# rustfmt (the post-generation hook formats the generated project).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$SCRIPT_DIR")"
TEMPLATE_PATH="${TEMPLATE_PATH:-$ROOT}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"

PROJECT_INPUT="orders-api"
PROJECT_ANSWER="example-app"
LEAN_VALUES="$TEMPLATE_PATH/template-values.toml"

if [[ -z "${WORKDIR:-}" ]]; then
	WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/template-values.XXXXXX")"
fi
mkdir -p "$WORKDIR"

cleanup() {
	if [[ "$KEEP_WORKDIR" != "1" ]]; then
		rm -rf "$WORKDIR"
	else
		echo "Fixture kept at $WORKDIR"
	fi
}
trap cleanup EXIT

fail() {
	echo "✗ $*" >&2
	exit 1
}

pass() { echo "✓ $*"; }

section() {
	echo
	echo "── $* ──"
}

gitc() { # <repo> <git args...>
	local repo="$1"
	shift
	git -C "$repo" -c user.name="Template Values Test" \
		-c user.email="template-values@example.com" "$@"
}

require_tools() {
	command -v cargo >/dev/null 2>&1 || fail "cargo is required"
	cargo generate --version >/dev/null 2>&1 || fail "cargo-generate is required"
	command -v git >/dev/null 2>&1 || fail "git is required"
	command -v python3 >/dev/null 2>&1 || fail "python3 is required"
	command -v rustfmt >/dev/null 2>&1 || command -v cargo-fmt >/dev/null 2>&1 ||
		echo "⚠  rustfmt not found; generated files may stay unformatted" >&2
}

toml_get() { # <file> <section> <key>
	awk -v section="$2" -v key="$3" '
		/^[[:space:]]*\[/ {
			s = $0; sub(/^[[:space:]]*\[/, "", s); sub(/\][[:space:]]*$/, "", s); next
		}
		s == section {
			line = $0
			if (line ~ ("^[[:space:]]*" key "[[:space:]]*=")) {
				sub(/^[^=]*=[[:space:]]*/, "", line); sub(/[[:space:]]+$/, "", line)
				if (line ~ /^".*"$/) { line = substr(line, 2, length(line) - 2) }
				print line; exit
			}
		}
	' "$1"
}

copy_template() { # <dest>
	local dest="$1"
	mkdir -p "$dest"
	tar -C "$TEMPLATE_PATH" \
		--exclude='./.git' --exclude='./target' --exclude='./generated' \
		-cf - . | tar -C "$dest" -xf -
}

# ── 1. Generation records the snapshot ────────────────────────────────────

section "generation snapshot"
require_tools

TEMPLATE_SRC="$WORKDIR/template"
copy_template "$TEMPLATE_SRC"
[[ -f "$LEAN_VALUES" ]] || fail "missing lean values fixture: $LEAN_VALUES"

GEN_DIR="$WORKDIR/generated"
mkdir -p "$GEN_DIR"
if ! cargo generate --path "$TEMPLATE_SRC" \
	--name "$PROJECT_INPUT" \
	--template-values-file "$LEAN_VALUES" \
	--silent --allow-commands \
	--destination "$GEN_DIR" >"$WORKDIR/generate.log" 2>&1; then
	tail -40 "$WORKDIR/generate.log" >&2
	fail "generation failed (see $WORKDIR/generate.log)"
fi

PROJECT="$GEN_DIR/$PROJECT_INPUT"
SNAPSHOT="$PROJECT/.cargo-generate/values.toml"
[[ -d "$PROJECT" ]] || fail "generated project not found at $PROJECT"
[[ -f "$SNAPSHOT" ]] || fail "generation did not write .cargo-generate/values.toml"
[[ ! -e "$PROJECT/.cargo-generate/.gitkeep" ]] || fail ".gitkeep was not removed after writing the snapshot"

python3 - "$SNAPSHOT" <<'PY' || fail "snapshot is not valid TOML"
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
assert "values" in data, "missing [values]"
assert "template" in data, "missing [template]"
assert data["values"]["project_name"], "missing project_name"
assert data["template"]["version"], "missing [template] version"
assert data["template"].get("name"), "missing [template] name"
PY

VERSION="$(toml_get "$SNAPSHOT" template version)"
[[ "$(toml_get "$SNAPSHOT" values project_name)" == "$PROJECT_ANSWER" ]] ||
	fail "project_name answer was not recorded"
[[ "$(toml_get "$SNAPSHOT" template name)" == "$PROJECT_INPUT" ]] ||
	fail "--name was not recorded in [template] name"
head -1 "$PROJECT/src/main.rs" | grep -q "use orders_api::" ||
	fail "crate name was not derived from --name"
pass "snapshot written with version $VERSION, name $PROJECT_INPUT"

# ── 2. Round trip ─────────────────────────────────────────────────────────

section "round trip from the snapshot"
ROUNDTRIP="$WORKDIR/roundtrip"
mkdir -p "$ROUNDTRIP"
if ! cargo generate --path "$TEMPLATE_SRC" \
	--name "$PROJECT_INPUT" \
	--template-values-file "$SNAPSHOT" \
	--silent --allow-commands \
	--destination "$ROUNDTRIP" >"$WORKDIR/roundtrip.log" 2>&1; then
	tail -40 "$WORKDIR/roundtrip.log" >&2
	fail "re-generation from the snapshot failed"
fi
diff -r --exclude=.git "$PROJECT" "$ROUNDTRIP/$PROJECT_INPUT" ||
	fail "re-generation from the snapshot is not byte-identical"
pass "snapshot reproduces the generated tree"

# ── 3. Scratch template with an upstream change ───────────────────────────

section "update from a newer template"
SCRATCH="$WORKDIR/scratch"
copy_template "$SCRATCH"
gitc "$SCRATCH" init -q -b main
gitc "$SCRATCH" add -A
gitc "$SCRATCH" commit -qm "template $VERSION"
gitc "$SCRATCH" tag "v$VERSION"

# Upstream changes: a release bump (both the config and the hook constant, as
# the release checklist requires), a file the project will also edit
# (conflict), a different line of the same file it edits locally (clean merge),
# a file it keeps, and a service-template change.
python3 - "$SCRATCH" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

cfg = root / "cargo-generate.toml"
cfg.write_text(cfg.read_text().replace('version = "1.0.0"', 'version = "1.1.0"', 1))
service_cfg = root / "service-template/cargo-generate.toml"
service_cfg.write_text(
    service_cfg.read_text().replace('version = "1.0.0"', 'version = "1.1.0"', 1)
)
hook = root / "post-generate.rhai"
hook.write_text(
    hook.read_text().replace(
        'const TEMPLATE_VALUES_VERSION = "1.0.0";',
        'const TEMPLATE_VALUES_VERSION = "1.1.0";',
        1,
    )
)
main = root / "src/main.rs"
main.write_text(main.read_text().replace("use tokio::signal;", "use tokio::signal::unix;", 1))
faq = root / "docs/FAQ.md"
faq.write_text(faq.read_text() + "\n<!-- upstream doc tweak -->\n")
service_readme = root / "service-template/README.md.liquid"
service_readme.write_text(service_readme.read_text() + "\nUpstream service tweak.\n")
PY
gitc "$SCRATCH" add -A
gitc "$SCRATCH" commit -qm "template 1.1.0"
gitc "$SCRATCH" tag v1.1.0

# Local changes in the generated project.
python3 - "$PROJECT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
main = root / "src/main.rs"
main.write_text(main.read_text().replace("use tokio::signal;", "use tokio::signal::ctrl_c;", 1))
faq = root / "docs/FAQ.md"
lines = faq.read_text().splitlines()
lines[0] = lines[0] + " (locally annotated)"
faq.write_text("\n".join(lines) + "\n")
arch = root / "docs/ARCHITECTURE.md"
arch.write_text(arch.read_text() + "\n<!-- local note -->\n")
PY

gitc "$PROJECT" init -q -b main 2>/dev/null || true
gitc "$PROJECT" add -A
gitc "$PROJECT" commit -qm "local changes"

# ── 4. Service snapshot (add-service) ─────────────────────────────────────

section "service snapshot"
if command -v yq >/dev/null 2>&1; then
	TEMPLATE_GIT_URL="$TEMPLATE_SRC" SERVICE_TEMPLATE_REF=main \
		bash "$PROJECT/scripts/add-service.sh" --name payments-api \
		>"$WORKDIR/add-service.log" 2>&1 ||
		{
			tail -40 "$WORKDIR/add-service.log" >&2
			fail "add-service failed"
		}
	SERVICE="$PROJECT/services/payments-api"
	SERVICE_SNAPSHOT="$SERVICE/.cargo-generate/values.toml"
	[[ -f "$SERVICE_SNAPSHOT" ]] || fail "add-service did not write $SERVICE_SNAPSHOT"
	[[ "$(toml_get "$SERVICE_SNAPSHOT" template name)" == "payments-api" ]] ||
		fail "service snapshot did not record [template] name"
	[[ "$(toml_get "$SERVICE_SNAPSHOT" template version)" == "$VERSION" ]] ||
		fail "service snapshot did not record the template version"

	SERVICE_ROUNDTRIP="$WORKDIR/service-roundtrip"
	mkdir -p "$SERVICE_ROUNDTRIP"
	cargo generate --path "$TEMPLATE_SRC" service-template \
		--name payments-api --init \
		--template-values-file "$SERVICE_SNAPSHOT" \
		--silent --destination "$SERVICE_ROUNDTRIP" \
		>"$WORKDIR/service-roundtrip.log" 2>&1 ||
		{
			tail -40 "$WORKDIR/service-roundtrip.log" >&2
			fail "service re-generation from its snapshot failed"
		}
	diff -r --exclude=.git --exclude=.cargo-generate "$SERVICE" "$SERVICE_ROUNDTRIP" ||
		fail "service snapshot does not reproduce services/payments-api"
	pass "service snapshot written and reproducible"

	gitc "$PROJECT" add -A
	gitc "$PROJECT" commit -qm "add payments-api"
else
	echo "⚠  yq not found; skipping the service snapshot checks" >&2
fi

# ── 5. Preview + apply ────────────────────────────────────────────────────

section "update preview"
if ! bash "$PROJECT/scripts/update-from-template.sh" \
	--template "$SCRATCH" --root-only >"$WORKDIR/preview.log" 2>&1; then
	tail -40 "$WORKDIR/preview.log" >&2
	fail "preview failed"
fi
cat "$WORKDIR/preview.log"
grep -q "conflicts (marked in the files):" "$WORKDIR/preview.log" ||
	fail "preview did not report the expected conflict"
grep -q "src/main.rs" "$WORKDIR/preview.log" ||
	fail "preview did not name the conflicting file"
grep -q "preview only" "$WORKDIR/preview.log" ||
	fail "preview should not claim to have written anything"
[[ ! -e "$PROJECT/src/main.rs.orig" ]] || fail "preview wrote into the worktree"
gitc "$PROJECT" diff --quiet || fail "preview modified the worktree"
pass "preview is read-only and reports the conflict"

section "update apply"
if ! bash "$PROJECT/scripts/update-from-template.sh" \
	--template "$SCRATCH" --root-only --apply >"$WORKDIR/apply.log" 2>&1; then
	tail -40 "$WORKDIR/apply.log" >&2
	fail "apply failed"
fi
cat "$WORKDIR/apply.log"

grep -q "<<<<<<<" "$PROJECT/src/main.rs" || fail "apply did not leave conflict markers"
grep -q "locally annotated" "$PROJECT/docs/FAQ.md" || fail "apply lost the local FAQ edit"
grep -q "upstream doc tweak" "$PROJECT/docs/FAQ.md" || fail "apply lost the upstream FAQ edit"
grep -q "local note" "$PROJECT/docs/ARCHITECTURE.md" || fail "apply lost a local-only edit"
if grep -q "upstream doc tweak" "$PROJECT/docs/ARCHITECTURE.md"; then
	fail "apply copied an upstream change into a file the template never changed"
fi
head -1 "$PROJECT/src/main.rs" | grep -q "use orders_api::" ||
	fail "apply changed the crate name"
grep -q "services/payments-api/deploy/overlays/dev" "$PROJECT/deploy/overlays/dev/kustomization.yaml" ||
	fail "apply dropped the overlay registration added by add-service"
[[ "$(toml_get "$SNAPSHOT" template name)" == "$PROJECT_INPUT" ]] ||
	fail "apply changed [template] name"
[[ "$(toml_get "$SNAPSHOT" template version)" == "1.1.0" ]] ||
	fail "apply did not advance the recorded template version"
pass "apply merged, preserved local work, and reported the conflict"

# ── 6. Service update ────────────────────────────────────────────────────

section "service update"
if [[ -d "$PROJECT/services/payments-api" ]]; then
	SERVICE="$PROJECT/services/payments-api"
	SERVICE_SNAPSHOT="$SERVICE/.cargo-generate/values.toml"

	# The service tree changed upstream, so the first update merges it.
	gitc "$PROJECT" add -A
	gitc "$PROJECT" commit -qm "apply root update"
	if ! bash "$PROJECT/scripts/update-from-template.sh" \
		--template "$SCRATCH" --service payments-api --apply >"$WORKDIR/service-apply.log" 2>&1; then
		tail -40 "$WORKDIR/service-apply.log" >&2
		fail "service update failed"
	fi
	cat "$WORKDIR/service-apply.log"
	grep -q "Upstream service tweak." "$SERVICE/README.md" ||
		fail "service update did not merge the upstream service-template change"
	grep -q "already up to date" "$WORKDIR/service-apply.log" &&
		fail "service update should not have been a no-op"
	[[ "$(toml_get "$SERVICE_SNAPSHOT" template version)" == "1.1.0" ]] ||
		fail "service update did not advance the recorded template version"

	# With the base advanced to v1.1.0 the second run is a no-op.
	gitc "$PROJECT" add -A
	gitc "$PROJECT" commit -qm "apply service update"
	if ! bash "$PROJECT/scripts/update-from-template.sh" \
		--template "$SCRATCH" --service payments-api >"$WORKDIR/service-noop.log" 2>&1; then
		tail -40 "$WORKDIR/service-noop.log" >&2
		fail "second service update failed"
	fi
	cat "$WORKDIR/service-noop.log"
	grep -q "already up to date" "$WORKDIR/service-noop.log" ||
		fail "second service update should report 'already up to date'"
	pass "service updates merge upstream changes and advance the base"
fi

echo
echo "✓ template values and update flow verified"
