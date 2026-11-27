#!/usr/bin/env bash
#
# update-from-template.sh - re-render the template with the recorded inputs and
# three-way merge the result into this project.
#
# Every generated project records its cargo-generate answers in
# `.cargo-generate/values.toml`; every service added with `make add-service`
# records its own `services/<slug>/.cargo-generate/values.toml`. This helper
# renders the template twice with those values:
#
#   base   = the template release recorded in the snapshot (tag v<version>)
#   theirs = the ref you update to (default: the recorded template ref)
#
# and three-way merges base -> theirs into your checkout, so your edits and the
# upstream changes are both preserved. Files you never touched are replaced;
# files you changed and the template did not are left alone.
#
# Preview is the default: nothing is written. `--apply` performs the merge.
#
# Usage:
#   scripts/update-from-template.sh [options]
#
# Options:
#   --apply                 Write the merge into the working tree
#   --diff                  Print the per-file unified diff in preview mode
#   --root-only             Only update the root project (skip services)
#   --service <slug>        Only update services/<slug>
#   --ref <ref>             Template ref to update to (branch, tag or revision)
#   --base-ref <ref>        Ref used as the merge base (default: v<version>)
#   --template <url|path>   Template source (default: the recorded repository)
#   --no-base               Skip the base render and report changes two-way
#   --force                 With --apply, allow a dirty git worktree
#   --keep                  Keep the temporary directory
#   --help                  Show this help
#
# Environment overrides:
#   TEMPLATE_GIT_URL        Template source (overrides the recorded repository)
#   TEMPLATE_REF            Template ref (root and services)
#   SERVICE_TEMPLATE_REF    Service template ref (services only)
#
# Requires: bash, git, cargo-generate >= 0.23.
#
# Exit status: 0 when the merge completed (conflicts are reported, not fatal),
# 1 on setup or render failures, 2 on usage errors.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$SCRIPT_DIR")"

SNAPSHOT_REL=".cargo-generate/values.toml"
ROOT_SNAPSHOT="$ROOT/$SNAPSHOT_REL"
SERVICE_TEMPLATE_ENV="$ROOT/scripts/service-template.env"

# ── CLI ───────────────────────────────────────────────────────────────────

APPLY=0
SHOW_DIFF=0
ROOT_ONLY=0
ONLY_SERVICE=""
OPT_REF=""
OPT_BASE_REF=""
OPT_TEMPLATE=""
NO_BASE=0
FORCE=0
KEEP=0

usage() {
	sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

usage_error() {
	echo "Error: $*" >&2
	echo >&2
	usage >&2
	exit 2
}

need_value() {
	if [[ -z "${2:-}" ]]; then
		usage_error "$1 requires a value"
	fi
	REPLY="$2"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--apply) APPLY=1 ;;
	--diff) SHOW_DIFF=1 ;;
	--root-only) ROOT_ONLY=1 ;;
	--service) need_value "$1" "${2:-}"; ONLY_SERVICE="$REPLY"; shift ;;
	--ref) need_value "$1" "${2:-}"; OPT_REF="$REPLY"; shift ;;
	--base-ref) need_value "$1" "${2:-}"; OPT_BASE_REF="$REPLY"; shift ;;
	--template) need_value "$1" "${2:-}"; OPT_TEMPLATE="$REPLY"; shift ;;
	--no-base) NO_BASE=1 ;;
	--force) FORCE=1 ;;
	--keep) KEEP=1 ;;
	-h | --help) usage; exit 0 ;;
	*) usage_error "unknown argument: $1" ;;
	esac
	shift
done

if [[ -n "$ONLY_SERVICE" && "$ROOT_ONLY" == 1 ]]; then
	usage_error "--service and --root-only are mutually exclusive"
fi

# ── Output helpers ────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
	BOLD=$'\033[0;1m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' RED=$'\033[0;31m' NC=$'\033[0m'
else
	BOLD="" GREEN="" YELLOW="" RED="" NC=""
fi

warn() { echo "${YELLOW}⚠  $*${NC}" >&2; }
die() {
	echo "${RED}✗ $*${NC}" >&2
	exit 1
}

# ── Small utilities ───────────────────────────────────────────────────────

# toml_lookup <file> <section> <key>
# Extracts a simple string/bool value. Only used for names, URLs, refs and the
# template version, so TOML string escapes are not decoded.
toml_lookup() {
	awk -v section="$2" -v key="$3" '
		/^[[:space:]]*\[/ {
			s = $0
			sub(/^[[:space:]]*\[/, "", s)
			sub(/\][[:space:]]*$/, "", s)
			next
		}
		s == section {
			line = $0
			if (line ~ ("^[[:space:]]*" key "[[:space:]]*=")) {
				sub(/^[^=]*=[[:space:]]*/, "", line)
				sub(/[[:space:]]+$/, "", line)
				if (line ~ /^".*"$/) {
					line = substr(line, 2, length(line) - 2)
				}
				print line
				exit
			}
		}
	' "$1"
}

# set_snapshot_version <file> <version>
#
# Rewrites `version = "..."` inside the [template] table, leaving everything
# else untouched. Returns non-zero when the table or key is absent.
set_snapshot_version() {
	local file="$1" version="$2" tmp
	tmp="$(mktemp "$TMP/snapshot.XXXXXX")"
	if ! awk -v version="$version" '
		/^[[:space:]]*\[/ {
			s = $0
			sub(/^[[:space:]]*\[/, "", s)
			sub(/\][[:space:]]*$/, "", s)
			in_template = (s == "template")
			print
			next
		}
		in_template == 1 && /^[[:space:]]*version[[:space:]]*=/ {
			print "version = \"" version "\""
			replaced = 1
			next
		}
		{ print }
		END { if (!replaced) { exit 3 } }
	' "$file" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$file"
}

# env_file_value <key> <file>
env_file_value() {
	awk -v key="$1" '
		$0 ~ ("^" key "=") {
			sub(/^[^=]*=/, "", $0)
			gsub(/^"|"$/, "", $0)
			print
			exit
		}
	' "$2"
}

ref_flag() {
	local ref="$1"
	if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
		echo --revision
	elif [[ "$ref" =~ ^v?[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]]; then
		echo --tag
	else
		echo --branch
	fi
}

file_is_binary() {
	! LC_ALL=C tr -d '\000' <"$1" | cmp -s - "$1"
}

list_files() {
	(cd "$1" 2>/dev/null && find . -type f -print | sed 's|^\./||') | LC_ALL=C sort
}

copy_tree() { # <src> <dst>
	local src="$1" dst="$2"
	mkdir -p "$dst"
	tar -C "$src" --exclude='./.git' --exclude='./target' --exclude='./generated' -cf - . |
		tar -C "$dst" -xf -
}

# ── Rendering ─────────────────────────────────────────────────────────────

# prepare_source <source> <ref>
#
# Produces a clean checkout of <ref>, cached per source+ref. Rendering from a
# checkout (instead of the working tree) is required because cargo-generate's
# `--path` reads the git index. Returns non-zero when <source> is neither a
# directory nor a clonable git URL.
prepare_source() {
	local source="$1" ref="$2" key dir
	key="$(printf '%s@%s' "$source" "$ref" | cksum | cut -d' ' -f1)"
	dir="$TMP/sources/$key"
	if [[ -d "$dir" ]]; then
		PREPARED_SOURCE="$dir"
		return 0
	fi
	mkdir -p "$TMP/sources"
	if ! git clone --quiet "$source" "$dir" >/dev/null 2>&1; then
		rm -rf "$dir"
		return 1
	fi
	if [[ -n "$ref" ]] && ! git -C "$dir" checkout --quiet "$ref" >/dev/null 2>&1; then
		warn "cannot check out '$ref' in $source"
		rm -rf "$dir"
		return 1
	fi
	PREPARED_SOURCE="$dir"
	return 0
}

# render <label> <source> <ref> <subfolder> <values> <dest> <project-name>
#
# Renders the template into <dest> and sets RENDERED_TEMPLATE_VERSION from the
# template's own `[template] version` (empty when it cannot be read).
render() {
	local label="$1" source="$2" ref="$3" subfolder="$4" values="$5" dest="$6" project="$7"
	local safe_label="${label//\//-}"
	local log="$TMP/logs/render-$safe_label.log"
	local -a args=()
	local config_root=""

	rm -rf "$dest"
	mkdir -p "$dest" "$TMP/logs"
	RENDERED_TEMPLATE_VERSION=""

	if prepare_source "$source" "$ref"; then
		source="$PREPARED_SOURCE"
		config_root="$source"
		if [[ -n "$subfolder" && -f "$source/$subfolder/cargo-generate.toml" ]]; then
			args+=(--path "$source" "$subfolder")
			config_root="$source/$subfolder"
		else
			args+=(--path "$source")
		fi
	elif [[ -d "$source" ]]; then
		# Not a git repository: render the working tree as-is (refs unavailable).
		warn "'$source' is not a git repository; rendering its working tree (ref ignored)"
		config_root="$source"
		if [[ -n "$subfolder" && -f "$source/$subfolder/cargo-generate.toml" ]]; then
			args+=(--path "$source" "$subfolder")
			config_root="$source/$subfolder"
		else
			args+=(--path "$source")
		fi
	else
		# Shorthand sources (`owner/repo`, `gh:...`) are left to cargo-generate.
		args+=(--git "$source")
		if [[ -n "$subfolder" ]]; then
			args+=("$subfolder")
		fi
		if [[ -n "$ref" ]]; then
			args+=("$(ref_flag "$ref")" "$ref")
		fi
	fi

	if [[ -n "$config_root" && -f "$config_root/cargo-generate.toml" ]]; then
		RENDERED_TEMPLATE_VERSION="$(toml_lookup "$config_root/cargo-generate.toml" template version)"
	fi

	if ! (cd "$ROOT" && cargo generate "${args[@]}" \
		--name "$project" \
		--template-values-file "$values" \
		--silent --allow-commands \
		--init --destination "$dest") >"$log" 2>&1; then
		echo "${RED}✗ template render failed ($label)${NC}" >&2
		tail -20 "$log" >&2
		if grep -qi "missing default value" "$log"; then
			echo >&2
			echo "  The template added a placeholder without a default. Add it to:" >&2
			echo "    $values" >&2
		fi
		echo "  Full log: $log" >&2
		return 1
	fi
	return 0
}

# ── Three-way merge ───────────────────────────────────────────────────────

ADDED=0 UPDATED=0 MERGED=0 DELETED=0 REFRESHED=0 CONFLICTS=0 KEPT=0
CHANGES_FILE=""
CONFLICT_FILE=""
WORK_DIR=""
TARGET_REF=""
BASE_LABEL=""
HAVE_BASE=0

record() { # <action> <rel>
	printf '%s\t%s\n' "$1" "$2" >>"$CHANGES_FILE"
	if [[ "$1" == "conflict" ]]; then
		printf '%s\n' "$2" >>"$CONFLICT_FILE"
	fi
}

stash_theirs() { # <theirs-file> <rel>
	local src="$1" rel="$2"
	mkdir -p "$WORK_DIR/new/$(dirname "$rel")"
	cp -p "$src" "$WORK_DIR/new/$rel"
}

merge_one() { # <root> <base> <theirs> <rel>
	local root="$1" base="$2" theirs="$3" rel="$4"
	local ours_f="$root/$rel" base_f="$base/$rel" theirs_f="$theirs/$rel"

	# Removed by the template.
	if [[ ! -f "$theirs_f" ]]; then
		[[ -f "$base_f" && -e "$ours_f" ]] || return 0
		if cmp -s "$ours_f" "$base_f"; then
			rm -f "$ours_f"
			DELETED=$((DELETED + 1))
			record deleted "$rel"
		else
			KEPT=$((KEPT + 1))
			record kept "$rel"
			warn "template removed $rel but you changed it; keeping your copy"
		fi
		return 0
	fi

	# The snapshot is derived data: the render already used our values, so the
	# freshly rendered copy is authoritative (it carries the new version).
	if [[ "$rel" == "$SNAPSHOT_REL" ]]; then
		if [[ -f "$ours_f" ]] && cmp -s "$ours_f" "$theirs_f"; then
			return 0
		fi
		mkdir -p "$(dirname "$ours_f")"
		cp -p "$theirs_f" "$ours_f"
		REFRESHED=$((REFRESHED + 1))
		record refreshed "$rel"
		return 0
	fi

	# New in the template (or no base to compare against).
	if [[ ! -f "$base_f" ]]; then
		if [[ ! -e "$ours_f" ]]; then
			mkdir -p "$(dirname "$ours_f")"
			cp -p "$theirs_f" "$ours_f"
			ADDED=$((ADDED + 1))
			record added "$rel"
		elif ! cmp -s "$ours_f" "$theirs_f"; then
			stash_theirs "$theirs_f" "$rel"
			KEPT=$((KEPT + 1))
			record kept "$rel"
			if [[ "$HAVE_BASE" == 1 ]]; then
				warn "template added $rel but you already have a different file; kept yours"
			else
				warn "template changed $rel and you have a different copy (no merge base); kept yours"
			fi
		fi
		return 0
	fi

	# Deleted locally.
	if [[ ! -e "$ours_f" ]]; then
		if ! cmp -s "$base_f" "$theirs_f"; then
			stash_theirs "$theirs_f" "$rel"
			KEPT=$((KEPT + 1))
			record kept "$rel"
			warn "template changed $rel but you deleted it; kept it deleted"
		fi
		return 0
	fi

	cmp -s "$ours_f" "$theirs_f" && return 0
	if cmp -s "$ours_f" "$base_f"; then
		cp -p "$theirs_f" "$ours_f"
		UPDATED=$((UPDATED + 1))
		record updated "$rel"
		return 0
	fi
	# Only changed locally.
	cmp -s "$theirs_f" "$base_f" && return 0

	# Changed on both sides.
	if file_is_binary "$ours_f" || file_is_binary "$theirs_f"; then
		stash_theirs "$theirs_f" "$rel"
		CONFLICTS=$((CONFLICTS + 1))
		record conflict "$rel"
		warn "binary file changed on both sides: $rel"
		return 0
	fi

	local merged="$WORK_DIR/merged.$$"
	local rc=0
	git merge-file --diff3 \
		-L "yours" -L "template@$BASE_LABEL" -L "template@$TARGET_REF" \
		-p "$ours_f" "$base_f" "$theirs_f" >"$merged" || rc=$?
	if [[ $rc -eq 0 ]]; then
		cp "$merged" "$ours_f"
		MERGED=$((MERGED + 1))
		record merged "$rel"
	elif [[ $rc -eq 255 ]]; then
		stash_theirs "$theirs_f" "$rel"
		CONFLICTS=$((CONFLICTS + 1))
		record conflict "$rel"
		warn "git merge-file failed for $rel; kept yours (upstream copy in new/)"
	else
		cp "$merged" "$ours_f"
		CONFLICTS=$((CONFLICTS + 1))
		record conflict "$rel"
	fi
	rm -f "$merged"
	return 0
}

merge_tree() { # <root> <base> <theirs>
	local root="$1" base="$2" theirs="$3" rel
	while IFS= read -r rel; do
		[[ -n "$rel" ]] || continue
		merge_one "$root" "$base" "$theirs" "$rel"
	done < <({ list_files "$theirs"; list_files "$base"; } | LC_ALL=C sort -u)
}

print_preview_diff() { # <pristine> <merged>
	local pristine="$1" merged="$2" act rel path_a path_b
	while IFS=$'\t' read -r act rel; do
		[[ -n "$rel" ]] || continue
		if [[ "$act" == "refreshed" ]]; then
			continue
		fi
		if [[ -e "$pristine/$rel" ]]; then
			path_a="$pristine/$rel"
		else
			path_a="$pristine/$rel.missing"
		fi
		if [[ -e "$merged/$rel" ]]; then
			path_b="$merged/$rel"
		else
			path_b="$merged/$rel.missing"
		fi
		diff -uN --label "a/$rel" --label "b/$rel" "$path_a" "$path_b" || true
	done <"$CHANGES_FILE"
}

print_summary() { # <label> <work>
	local label="$1" work="$2"
	local total=$((ADDED + UPDATED + MERGED + DELETED + REFRESHED))
	echo "   ${GREEN}added $ADDED${NC}, updated $UPDATED, merged $MERGED, refreshed $REFRESHED, deleted $DELETED" \
		"${YELLOW}kept $KEPT${NC} ${RED}conflicts $CONFLICTS${NC}"
	if [[ "$total" -eq 0 && "$KEPT" -eq 0 && "$CONFLICTS" -eq 0 ]]; then
		echo "   ${GREEN}✓ already up to date with the template${NC}"
	fi
	if [[ -s "$CONFLICT_FILE" ]]; then
		echo "   ${RED}conflicts (marked in the files):${NC}"
		sed 's/^/     - /' "$CONFLICT_FILE"
	fi
	if [[ -d "$work/new" ]]; then
		echo "   upstream copies for unresolved files: $work/new"
	fi
}

# ── Per-target orchestration ──────────────────────────────────────────────

update_target() { # <label> <ours> <snapshot> <source> <ref> <subfolder> <project> <version>
	local label="$1" ours="$2" snapshot="$3" source="$4" ref="$5" subfolder="$6" project="$7" version="$8"

	WORK_DIR="$TMP/$label"
	TARGET_REF="$ref"
	BASE_LABEL="${OPT_BASE_REF:-v$version}"
	ADDED=0 UPDATED=0 MERGED=0 DELETED=0 REFRESHED=0 CONFLICTS=0 KEPT=0
	rm -rf "$WORK_DIR"
	mkdir -p "$WORK_DIR/logs"
	CHANGES_FILE="$WORK_DIR/changes.tsv"
	CONFLICT_FILE="$WORK_DIR/conflicts.txt"
	: >"$CHANGES_FILE"
	: >"$CONFLICT_FILE"

	echo
	echo "${BOLD}== $label ==${NC}"
	echo "   template: $source${subfolder:+ (subfolder $subfolder)}"
	echo "   updating to: $ref"
	local theirs_dir="$WORK_DIR/theirs" base_dir="$WORK_DIR/base"
	mkdir -p "$base_dir"

	if ! render "$label-theirs" "$source" "$ref" "$subfolder" "$snapshot" "$theirs_dir" "$project"; then
		return 1
	fi
	# The service template does not render a snapshot of its own; remember the
	# target release so the recorded merge base can advance after the update.
	local target_version="$RENDERED_TEMPLATE_VERSION"

	local have_base=0
	if [[ "$NO_BASE" == 0 && -n "$version" ]]; then
		if render "$label-base" "$source" "${OPT_BASE_REF:-v$version}" "$subfolder" "$snapshot" "$base_dir" "$project"; then
			have_base=1
		else
			warn "could not render the merge base at '${OPT_BASE_REF:-v$version}'; reporting changes two-way"
		fi
	fi
	if [[ "$have_base" == 0 ]]; then
		rm -rf "$base_dir"
		mkdir -p "$base_dir"
	fi
	HAVE_BASE="$have_base"

	local workroot
	if [[ "$APPLY" == 1 ]]; then
		workroot="$ours"
	else
		workroot="$WORK_DIR/preview"
		copy_tree "$ours" "$workroot"
	fi

	merge_tree "$workroot" "$base_dir" "$theirs_dir"

	# Services: advance the recorded merge base to the release we just rendered.
	if [[ "$subfolder" == "service-template" && -n "$target_version" ]]; then
		local svc_snapshot="$workroot/$SNAPSHOT_REL"
		if [[ -f "$svc_snapshot" ]] &&
			[[ "$(toml_lookup "$svc_snapshot" template version)" != "$target_version" ]]; then
			if set_snapshot_version "$svc_snapshot" "$target_version"; then
				REFRESHED=$((REFRESHED + 1))
				record refreshed "$SNAPSHOT_REL"
			else
				warn "could not update the template version in $svc_snapshot"
			fi
		fi
	fi

	print_summary "$label" "$WORK_DIR"
	if [[ "$APPLY" == 0 && "$SHOW_DIFF" == 1 ]]; then
		echo
		print_preview_diff "$ours" "$workroot"
	fi
	if [[ "$APPLY" == 0 ]]; then
		echo "   ${GREEN}preview only — re-run with --apply (make template-update APPLY=1) to write it${NC}"
	fi
	return 0
}

# ── Target discovery ──────────────────────────────────────────────────────

require_snapshot() {
	if [[ ! -f "$ROOT_SNAPSHOT" ]]; then
		die "missing $SNAPSHOT_REL — this project predates generation-input snapshots.
  Regenerate once from the template to create it, then re-run this helper."
	fi
}

check_git_clean() {
	if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		die "--apply needs a git worktree so changes can be reviewed (git init first)"
	fi
	if ! git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
		die "the git repository has no commits yet; commit the project before applying a template update"
	fi
	if [[ "$FORCE" == 1 ]]; then
		return 0
	fi
	if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
		die "the git worktree has uncommitted changes; commit or stash them first (or use --force)"
	fi
}

root_template_source() {
	local snapshot="$1" source="${OPT_TEMPLATE:-${TEMPLATE_GIT_URL:-}}"
	if [[ -z "$source" ]]; then
		source="$(toml_lookup "$snapshot" values template_repo_url)"
	fi
	printf '%s' "$source"
}

root_template_ref() {
	local snapshot="$1" ref="${OPT_REF:-${TEMPLATE_REF:-}}"
	if [[ -z "$ref" ]]; then
		ref="$(toml_lookup "$snapshot" values template_ref)"
	fi
	[[ -n "$ref" ]] || ref="main"
	printf '%s' "$ref"
}

# The `--name` used at generation time decides the crate name; fall back to the
# project_name answer for snapshots written before it was recorded.
root_template_name() {
	local snapshot="$1" name
	name="$(toml_lookup "$snapshot" template name)"
	[[ -n "$name" ]] || name="$(toml_lookup "$snapshot" values project_name)"
	printf '%s' "$name"
}

service_template_source() {
	local source="${OPT_TEMPLATE:-${TEMPLATE_GIT_URL:-}}"
	if [[ -z "$source" && -f "$SERVICE_TEMPLATE_ENV" ]]; then
		source="$(env_file_value TEMPLATE_REPO_URL "$SERVICE_TEMPLATE_ENV")"
	fi
	printf '%s' "$source"
}

service_template_ref() {
	local ref="${OPT_REF:-${SERVICE_TEMPLATE_REF:-}}"
	if [[ -z "$ref" && -f "$SERVICE_TEMPLATE_ENV" ]]; then
		ref="$(env_file_value TEMPLATE_REF "$SERVICE_TEMPLATE_ENV")"
	fi
	[[ -n "$ref" ]] || ref="main"
	printf '%s' "$ref"
}

service_snapshots() {
	local dir
	for dir in "$ROOT"/services/*/; do
		[[ -d "$dir" ]] || continue
		[[ -f "$dir$SNAPSHOT_REL" ]] || continue
		printf '%s\n' "${dir%/}"
	done | LC_ALL=C sort
}

# ── Main ──────────────────────────────────────────────────────────────────

TMP="$(mktemp -d "${TMPDIR:-/tmp}/template-update.XXXXXX")"
cleanup() {
	if [[ "$KEEP" == 1 ]]; then
		echo "Temporary directory kept: $TMP"
	else
		rm -rf "$TMP"
	fi
}
trap cleanup EXIT

command -v cargo >/dev/null 2>&1 || die "cargo is required"
if ! cargo generate --version >/dev/null 2>&1; then
	die "cargo-generate is required: cargo install cargo-generate --locked"
fi
command -v git >/dev/null 2>&1 || die "git is required"

require_snapshot

ROOT_NAME="$(toml_lookup "$ROOT_SNAPSHOT" values project_name)"
ROOT_VERSION="$(toml_lookup "$ROOT_SNAPSHOT" template version)"
[[ -n "$ROOT_NAME" ]] || die "project_name is missing from $SNAPSHOT_REL"
RENDER_NAME="$(root_template_name "$ROOT_SNAPSHOT")"
[[ -n "$RENDER_NAME" ]] || RENDER_NAME="$ROOT_NAME"

if [[ "$APPLY" == 1 ]]; then
	check_git_clean
fi

ROOT_SRC="$(root_template_source "$ROOT_SNAPSHOT")"
ROOT_REF="$(root_template_ref "$ROOT_SNAPSHOT")"
[[ -n "$ROOT_SRC" ]] || die "no template source: set TEMPLATE_GIT_URL or pass --template"

if [[ -n "$ONLY_SERVICE" ]]; then
	SVC_DIR="$ROOT/services/$(echo "$ONLY_SERVICE" | tr '_' '-')"
	[[ -f "$SVC_DIR/$SNAPSHOT_REL" ]] || die "no snapshot at services/${ONLY_SERVICE}/$SNAPSHOT_REL"
fi

echo "${BOLD}Template update${NC} ($([[ "$APPLY" == 1 ]] && echo apply || echo preview))"

if [[ -z "$ONLY_SERVICE" ]]; then
	update_target "root" "$ROOT" "$ROOT_SNAPSHOT" "$ROOT_SRC" "$ROOT_REF" "" "$RENDER_NAME" "$ROOT_VERSION"
fi

if [[ "$ROOT_ONLY" == 0 ]]; then
	SVC_SRC="$(service_template_source)"
	SVC_REF="$(service_template_ref)"
	if [[ -z "$SVC_SRC" ]]; then
		if [[ -n "$ONLY_SERVICE" ]]; then
			die "no service-template source: scripts/service-template.env is missing; pass --template"
		fi
		warn "no service-template source (scripts/service-template.env missing); skipping services"
	else
		while IFS= read -r svc_dir; do
			[[ -n "$svc_dir" ]] || continue
			slug="$(basename "$svc_dir")"
			if [[ -n "$ONLY_SERVICE" && "$slug" != "$(echo "$ONLY_SERVICE" | tr '_' '-')" ]]; then
				continue
			fi
			snapshot="$svc_dir/$SNAPSHOT_REL"
			svc_name="$(toml_lookup "$snapshot" template name)"
			[[ -n "$svc_name" ]] || svc_name="$(toml_lookup "$snapshot" values service_slug)"
			[[ -n "$svc_name" ]] || svc_name="$slug"
			svc_version="$(toml_lookup "$snapshot" template version)"
			[[ -n "$svc_version" ]] || svc_version="$ROOT_VERSION"
			update_target "service/$slug" "$svc_dir" "$snapshot" "$SVC_SRC" "$SVC_REF" "service-template" "$svc_name" "$svc_version"
		done < <(service_snapshots)
	fi
fi

echo
if [[ "$APPLY" == 1 ]]; then
	echo "${GREEN}✓ merge applied${NC} — review with: git diff"
	echo "  Then run: cargo fmt --all && cargo test"
	echo "  Resolve any conflicts (search for '<<<<<<<') before committing."
else
	echo "${GREEN}✓ preview complete${NC} — nothing was written"
	echo "  Apply with: make template-update APPLY=1"
fi
