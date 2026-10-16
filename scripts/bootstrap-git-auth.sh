#!/usr/bin/env bash
# Create the flux-system Secret that Flux uses to pull this repository over SSH
# (keys: identity / identity.pub / known_hosts) and help register the matching
# public key as a GitHub deploy key.
#
# Usage: scripts/bootstrap-git-auth.sh [SECRET_NAME] [--key PATH] [--sops]
#
#   SECRET_NAME   Secret name (default: spec.secretRef.name from
#                 deploy/flux/git-repository.yaml)
#   --key PATH    SSH private key to use or create
#                 (default: ~/.ssh/<project>-deploy-key)
#   --sops        also write an encrypted copy to
#                 deploy/flux/bootstrap/github-deploy-key.sops.yaml
#                 (requires sops and a .sops.yaml with your age recipient)
#
# The Secret cannot be managed by Flux itself (Flux needs it to reach the
# repository), so re-run this once per cluster that needs access.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}→${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

GIT_REPO_FILE="deploy/flux/git-repository.yaml"
[[ -f "$GIT_REPO_FILE" ]] || die "missing $GIT_REPO_FILE"
command -v kubectl >/dev/null || die "kubectl not found"
command -v ssh-keyscan >/dev/null || die "ssh-keyscan not found (install openssh-client)"
command -v yq >/dev/null || die "yq not found"

SECRET_NAME=""
KEY_PATH=""
WRITE_SOPS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY_PATH="${2:?--key needs a path}"; shift 2 ;;
    --sops) WRITE_SOPS=true; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) SECRET_NAME="$1"; shift ;;
  esac
done

PROJECT_NAME="$(basename "$PROJECT_ROOT")"
SECRET_NAME="${SECRET_NAME:-$(yq -r '.spec.secretRef.name // ""' "$GIT_REPO_FILE")}"
if [[ -z "$SECRET_NAME" ]]; then
  die "no secretRef in $GIT_REPO_FILE — set 'git_auth_secret' when generating (or pass SECRET_NAME and edit the GitRepository) to use SSH"
fi

KEY_PATH="${KEY_PATH:-$HOME/.ssh/${PROJECT_NAME}-deploy-key}"
FLUX_NAMESPACE="flux-system"

if [[ ! -f "$KEY_PATH" ]]; then
  info "Generating a new ed25519 deploy key at $KEY_PATH"
  mkdir -p "$(dirname "$KEY_PATH")"
  ssh-keygen -t ed25519 -N "" -C "${PROJECT_NAME} flux deploy key" -f "$KEY_PATH" >/dev/null
else
  info "Reusing existing key $KEY_PATH"
fi

echo ""
echo "Public key (GitHub → Repository → Settings → Deploy keys → Add deploy key;"
echo "write access is not required):"
echo "  $(cat "${KEY_PATH}.pub")"
echo ""

REPO_SLUG=""
ORIGIN_URL="$(git config --get remote.origin.url 2>/dev/null || true)"
if [[ -n "$ORIGIN_URL" ]]; then
  REPO_SLUG="$(echo "$ORIGIN_URL" | sed -E 's#(git@github.com:|ssh://git@github.com/|https://github.com/)##; s#\.git$##')"
fi

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1 && [[ -n "$REPO_SLUG" ]]; then
  if gh repo deploy-key add "${KEY_PATH}.pub" --title "${PROJECT_NAME}-flux" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    ok "Deploy key registered on GitHub ($REPO_SLUG)"
  else
    warn "Could not add the deploy key via gh (maybe it already exists) — verify manually."
  fi
else
  warn "Register the key with: gh repo deploy-key add ${KEY_PATH}.pub --repo <owner>/<repo>"
fi

KNOWN_HOSTS="$(mktemp)"
trap 'rm -f "$KNOWN_HOSTS"' EXIT
ssh-keyscan -t rsa,ecdsa,ed25519 github.com >"$KNOWN_HOSTS" 2>/dev/null
[[ -s "$KNOWN_HOSTS" ]] || die "ssh-keyscan github.com returned nothing (are you online?)"

info "Applying Secret ${FLUX_NAMESPACE}/${SECRET_NAME} to the current cluster context ($(kubectl config current-context 2>/dev/null || echo unknown))..."
kubectl create secret generic "$SECRET_NAME" -n "$FLUX_NAMESPACE" \
  --from-file=identity="$KEY_PATH" \
  --from-file=identity.pub="${KEY_PATH}.pub" \
  --from-file=known_hosts="$KNOWN_HOSTS" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "Secret applied"

if [[ "$WRITE_SOPS" == true ]]; then
  command -v sops >/dev/null || die "--sops requires the sops binary"
  [[ -f .sops.yaml ]] || die "--sops requires .sops.yaml (start from .sops.yaml.example and set your age recipient)"
  OUT="deploy/flux/bootstrap/github-deploy-key.sops.yaml"
  mkdir -p "$(dirname "$OUT")"
  kubectl create secret generic "$SECRET_NAME" -n "$FLUX_NAMESPACE" \
    --from-file=identity="$KEY_PATH" \
    --from-file=identity.pub="${KEY_PATH}.pub" \
    --from-file=known_hosts="$KNOWN_HOSTS" \
    --dry-run=client -o yaml >"$OUT"
  sops -e -i "$OUT"
  ok "Encrypted copy written to $OUT (commit it for reproducible bootstraps)"
fi

echo ""
ok "Git auth ready: Flux can pull over SSH via secretRef '$SECRET_NAME'."
info "Next: make deploy dev   (commit + push + apply the Flux bootstrap)"
