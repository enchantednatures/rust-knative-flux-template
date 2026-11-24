#!/usr/bin/env bash
#
# common.sh — shared output helpers for the local development scripts.
#
# This file is meant to be sourced, never executed:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"
#
# It defines only functions and colour constants, so it is safe to source under
# `set -u` / `set -e` and produces no output on its own.

# Guard against being sourced twice (e.g. a helper script sourcing another one).
if [[ -z "${_RKFT_COMMON_SH_SOURCED:-}" ]]; then
  _RKFT_COMMON_SH_SOURCED=1

  # Colour constants. Disable when stdout is not a terminal or NO_COLOR is set
  # (https://no-color.org/).
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
  else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
  fi

  # Print an informational message to stdout.
  info() {
    printf '%b\n' "${BLUE}[INFO]${NC}  $*"
  }

  # Print a warning to stderr.
  warn() {
    printf '%b\n' "${YELLOW}[WARN]${NC}  $*" >&2
  }

  # Print an error to stderr.
  error() {
    printf '%b\n' "${RED}[ERROR]${NC} $*" >&2
  }

  # Print a success message to stdout.
  success() {
    printf '%b\n' "${GREEN}[ OK ]${NC}  $*"
  }

  # Print a section heading.
  section() {
    printf '\n%b\n' "${CYAN}=== $* ===${NC}"
  }
fi
