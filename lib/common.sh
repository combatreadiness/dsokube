# shellcheck shell=bash
# =============================================================
# lib/common.sh — shared by dsokube (sourced, not run)
# =============================================================

log()  { echo -e "  \e[1;32m✔\e[0m $*"; }
warn() { echo -e "  \e[1;33m⚠\e[0m $*"; }
bad()  { echo -e "  \e[1;31m✖\e[0m $*"; }
die()  { echo -e "  \e[1;31m✖\e[0m $*" >&2; exit 1; }
info() { echo -e "    \e[2m$*\e[0m"; }
step() { echo -e "\n\e[1m▸ $*\e[0m"; }

# load_versions  -> K3S_VERSION, K3S_ANSIBLE_VERSION, KUBECTL_VERSION (variables already set win)
load_versions() {
  local key value
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="${value%%#*}"; value="${value%"${value##*[![:space:]]}"}"
    [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$value"
  done < "${SCRIPT_DIR}/versions.env"
}

# version_ge <a> <b>  -> exit 0 when a >= b (dotted numbers)
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }
