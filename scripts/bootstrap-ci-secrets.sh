#!/usr/bin/env bash
# Set the KELLNR_TOKEN GitHub Actions secret for this repository.
#
# The generated CI and Docker builds resolve axum-cloudevents from the private
# Kellnr registry and read the token from the KELLNR_TOKEN repository secret.
# This helper reads the token from the local Cargo configuration (or the
# environment) and calls `gh secret set`, so a fresh checkout can be made
# CI-ready with one command:
#
#   make ci-secrets
#
# Usage:
#   scripts/bootstrap-ci-secrets.sh [--repo OWNER/NAME] [--check] [--dry-run]
#                                   [--optional]
#
#   --repo OWNER/NAME  Repository to update (default: --repo from the Makefile,
#                      GH_REPO, the origin remote, or `gh repo view`)
#   --check            Only report whether KELLNR_TOKEN is set
#   --dry-run          Resolve the token/repository and print the plan without
#                      calling gh secret set (works without gh authentication)
#   --optional         Warn and exit 0 on setup problems (used by `make deploy`)
#
# Token resolution (first match wins):
#   1. CARGO_REGISTRIES_KELLNR_TOKEN
#   2. KELLNR_TOKEN
#   3. $CARGO_HOME/credentials.toml -> [registries.kellnr] token
#   4. $CARGO_HOME/config.toml      -> [registries.kellnr] token
#
# The token is never printed and is passed to gh on stdin. No token is stored
# in this repository.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}→${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Usage: scripts/bootstrap-ci-secrets.sh [--repo OWNER/NAME] [--check] [--dry-run] [--optional]

Sets the KELLNR_TOKEN GitHub Actions secret used by CI and Docker builds to
resolve axum-cloudevents from the private Kellnr registry.

Options:
  --repo OWNER/NAME  Repository to update (default: origin remote / gh repo view)
  --check            Only report whether KELLNR_TOKEN is set
  --dry-run          Resolve token and repository, print the plan, do not call gh
  --optional         Warn and exit 0 on setup problems (make deploy preflight)
  -h, --help         Show this help

Token sources (first match wins):
  CARGO_REGISTRIES_KELLNR_TOKEN
  KELLNR_TOKEN
  $CARGO_HOME/credentials.toml [registries.kellnr] token
  $CARGO_HOME/config.toml      [registries.kellnr] token
EOF
}

REPO=""
MODE="set"
DRY_RUN=false
OPTIONAL=false
while [[ $# -gt 0 ]]; do
	case "$1" in
		--repo) REPO="${2:?--repo needs OWNER/NAME}"; shift 2 ;;
		--check) MODE="check"; shift ;;
		--dry-run) DRY_RUN=true; shift ;;
		--optional) OPTIONAL=true; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown flag: $1 (see --help)" ;;
		*) die "unexpected argument: $1 (see --help)" ;;
	esac
done

# In --optional mode, setup problems are warnings so `make deploy` can continue.
skip() {
	warn "$*"
	if $OPTIONAL && [[ "$MODE" != "check" ]]; then
		exit 0
	fi
	exit 1
}

# Treat the template's untouched defaults as "not configured".
is_placeholder_repo() {
	local repo="$1"
	[[ -z "$repo" ]] && return 0
	[[ "$repo" == *"{"* || "$repo" == *"}"* ]] && return 0
	[[ "$repo" == "your-org/your-repo" || "$repo" == "OWNER/NAME" ]] && return 0
	return 1
}

parse_github_repo() {
	local url="$1"
	url="${url%.git}"
	case "$url" in
		git@github.com:*) printf '%s' "${url#git@github.com:}" ;;
		ssh://git@github.com/*) printf '%s' "${url#ssh://git@github.com/}" ;;
		https://github.com/*) printf '%s' "${url#https://github.com/}" ;;
		http://github.com/*) printf '%s' "${url#http://github.com/}" ;;
		*) return 1 ;;
	esac
}

# Read the token from [registries.kellnr] in a Cargo config/credentials file.
registry_token_from() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	awk '
		/^[[:space:]]*\[/ {
			in_section = ($0 ~ /^[[:space:]]*\[registries\.kellnr\][[:space:]]*$/)
			next
		}
		in_section && /^[[:space:]]*token[[:space:]]*=/ {
			line = $0
			sub(/^[^=]*=[[:space:]]*"/, "", line)
			sub(/".*$/, "", line)
			print line
			exit
		}
	' "$file"
}

resolve_token() {
	local cargo_home="${CARGO_HOME:-$HOME/.cargo}" candidate=""
	if [[ -n "${CARGO_REGISTRIES_KELLNR_TOKEN:-}" ]]; then
		TOKEN="$CARGO_REGISTRIES_KELLNR_TOKEN"
		TOKEN_SOURCE="CARGO_REGISTRIES_KELLNR_TOKEN"
		return 0
	fi
	if [[ -n "${KELLNR_TOKEN:-}" ]]; then
		TOKEN="$KELLNR_TOKEN"
		TOKEN_SOURCE="KELLNR_TOKEN"
		return 0
	fi
	local file
	for file in credentials.toml credentials config.toml; do
		candidate="$(registry_token_from "$cargo_home/$file")"
		if [[ -n "$candidate" ]]; then
			TOKEN="$candidate"
			TOKEN_SOURCE="$cargo_home/$file"
			return 0
		fi
	done
	return 1
}

# Prefer the explicit --repo (which make passes from the generated project),
# then GH_REPO, the origin remote, and finally `gh repo view`.
if is_placeholder_repo "$REPO"; then
	REPO=""
fi
if [[ -z "$REPO" && -n "${GH_REPO:-}" ]]; then
	REPO="$GH_REPO"
fi
if [[ -z "$REPO" ]]; then
	origin="$(git config --get remote.origin.url 2>/dev/null || true)"
	if [[ -n "$origin" ]]; then
		REPO="$(parse_github_repo "$origin" || true)"
	fi
fi
if [[ -z "$REPO" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if is_placeholder_repo "$REPO"; then
	REPO=""
fi
[[ -n "$REPO" ]] || skip "cannot determine the GitHub repository; pass --repo OWNER/NAME"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || skip "invalid repository '$REPO'; expected OWNER/NAME"

# --check only needs gh, not the token.
if [[ "$MODE" == "check" ]]; then
	command -v gh >/dev/null 2>&1 || skip "gh not found; install the GitHub CLI (https://cli.github.com)"
	gh auth status >/dev/null 2>&1 || skip "gh is not authenticated; run 'gh auth login'"
	if gh secret list --repo "$REPO" 2>/dev/null | awk '{ print $1 }' | grep -qx 'KELLNR_TOKEN'; then
		ok "KELLNR_TOKEN is set for $REPO"
		exit 0
	fi
	warn "KELLNR_TOKEN is not set for $REPO"
	exit 1
fi

resolve_token || skip "no Kellnr token found; run 'cargo login --registry kellnr' or export CARGO_REGISTRIES_KELLNR_TOKEN"

if $DRY_RUN; then
	ok "Would set KELLNR_TOKEN for $REPO (token from $TOKEN_SOURCE)"
	exit 0
fi

command -v gh >/dev/null 2>&1 || skip "gh not found; install the GitHub CLI (https://cli.github.com)"
gh auth status >/dev/null 2>&1 || skip "gh is not authenticated; run 'gh auth login'"
gh repo view "$REPO" >/dev/null 2>&1 || skip "cannot access $REPO with gh (does the repository exist?)"

info "Setting KELLNR_TOKEN for $REPO (token from $TOKEN_SOURCE)..."
if ! printf '%s' "$TOKEN" | gh secret set KELLNR_TOKEN --repo "$REPO"; then
	skip "failed to set KELLNR_TOKEN for $REPO"
fi
unset TOKEN
ok "KELLNR_TOKEN set for $REPO"

if gh secret list --repo "$REPO" 2>/dev/null | awk '{ print $1 }' | grep -qx 'KELLNR_TOKEN'; then
	ok "Verified: KELLNR_TOKEN is listed for $REPO"
else
	warn "KELLNR_TOKEN was set, but the secret list did not show it yet"
fi
