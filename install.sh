#!/usr/bin/env bash
# =============================================================
# install.sh — entry point for dsokube
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/dsokube/main/install.sh)"
#
# Run on the machine that runs Ansible (a proxmox-iac-bootstrap management node,
# or any Linux box with ansible-core 2.15+ that can SSH to the nodes), as root.
#
# What it does, in order:
#   1) Checks: root, required commands, ansible-core version (warns only)
#   2) Downloads one release archive (+ SHA256SUMS) into a temp folder and verifies it
#   3) Installs to /usr/local/lib/dsokube, links /usr/local/bin/dsokube
#   (k3s-ansible itself is fetched on the first `dsokube up`, into ~/.config/dsokube)
#
# Environment (all optional):
#   DSOKUBE_REF=latest|vX.Y.Z|main   What to install (default: latest release)
#   DSOKUBE_REPO=owner/name          Install from a fork
#   DSOKUBE_SRC=/path/to/checkout    Install from a local folder instead of GitHub (development)
# Re-run  : Safe. Replaces the installed files; your clusters in ~/.config/dsokube stay.
# =============================================================
set -euo pipefail

NAME="dsokube"
REPO="${DSOKUBE_REPO:-combatreadiness/dsokube}"
REF="${DSOKUBE_REF:-latest}"
SRC="${DSOKUBE_SRC:-}"
LIB_DIR="/usr/local/lib/${NAME}"
BIN_LINK="/usr/local/bin/${NAME}"
REQUIRED_FILES=(dsokube versions.env lib/common.sh lib/checks.sh)
NEEDS=(curl tar gzip sha256sum jq ssh)

# ---------- Output (same look as proxmox-iac-bootstrap) ----------
GN=$'\e[1;32m'; YW=$'\e[1;33m'; RD=$'\e[1;31m'; BL=$'\e[1;36m'; DIM=$'\e[2m'; CL=$'\e[0m'
msg_info() { printf '  %s…%s %s' "$YW" "$CL" "$1"; }
msg_ok()   { printf '\r\e[K  %s✔%s %s\n' "$GN" "$CL" "$1"; }
msg_skip() { printf '\r\e[K  %s–%s %s\n' "$YW" "$CL" "$1"; }
msg_err()  { printf '\r\e[K  %s✖%s %s\n' "$RD" "$CL" "$1" >&2; exit 1; }

cat <<BANNER
${BL}
   ┌──────────────────────────────────────────────┐
   │   dsokube                                    │
   │   K3s on any Ansible inventory · k3s-ansible │
   └──────────────────────────────────────────────┘
${CL}
BANNER

TMP=""
cleanup() { if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

# =============================================================
echo "${DIM}  This machine${CL}"
# =============================================================
[[ $EUID -eq 0 ]] || msg_err "Run as root (it installs to ${LIB_DIR})."
for c in "${NEEDS[@]}"; do
  command -v "$c" >/dev/null || msg_err "Missing command: $c (apt install $c)"
done
msg_ok "Required commands present"
if command -v ansible >/dev/null; then
  av="$(ansible --version | sed -n '1s/.*core \([0-9.]*\).*/\1/p')"
  if [[ "$(printf '%s\n' 2.15 "$av" | sort -V | head -n1)" == "2.15" ]]; then
    msg_ok "ansible-core ${av}"
  else
    msg_skip "ansible-core ${av} is too old (k3s-ansible needs 2.15+). See README: Requirements"
  fi
else
  msg_skip "Ansible not found. dsokube needs ansible-core 2.15+. See README: Requirements"
fi

# =============================================================
echo; echo "${DIM}  Download${CL}"
# =============================================================
TMP="$(mktemp -d)"
cd "$TMP"

fetch() {  # fetch <url> <file>
  curl -fsSL --proto '=https' --retry 3 --retry-delay 2 -o "$2" "$1" || msg_err "Download failed: $1"
}

if [[ -n "$SRC" ]]; then
  [[ -d "$SRC" ]] || msg_err "DSOKUBE_SRC is not a folder: ${SRC}"
  mkdir src
  (cd "$SRC" && tar --exclude=.git -cf - .) | tar -xf - -C src
  TAG="local"
  if command -v git >/dev/null && git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then
    TAG="local-$(git -C "$SRC" rev-parse --short HEAD)"
  fi
  echo "$TAG" > src/VERSION
  msg_skip "Using local folder ${SRC} (${TAG}), no checksum"
else
  msg_info "Finding release"
  if [[ "$REF" == "latest" ]]; then
    url=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest") \
      || msg_err "Cannot reach GitHub to find the latest release."
    TAG="${url##*/}"
    [[ "$TAG" == v* ]] || msg_err "No release found for ${REPO}. Use DSOKUBE_REF=main to install from the branch."
  else
    TAG="$REF"
  fi
  msg_ok "${REPO} ${TAG}"

  if [[ "$TAG" == v* ]]; then
    ARCHIVE="${NAME}-${TAG}.tar.gz"
    base="https://github.com/${REPO}/releases/download/${TAG}"
    msg_info "Downloading ${ARCHIVE}"
    fetch "${base}/${ARCHIVE}" "$ARCHIVE"
    fetch "${base}/SHA256SUMS" SHA256SUMS
    msg_ok "Downloaded ${ARCHIVE}"
    line=$(grep -E "  ${ARCHIVE}\$" SHA256SUMS || true)
    [[ -n "$line" ]] || msg_err "${ARCHIVE} is not listed in SHA256SUMS."
    echo "$line" | sha256sum -c --quiet - >/dev/null 2>&1 || msg_err "Checksum mismatch for ${ARCHIVE}."
    msg_ok "SHA256 verified"
  else
    ARCHIVE="${NAME}-src.tar.gz"
    msg_info "Downloading ${TAG}"
    fetch "https://github.com/${REPO}/archive/${TAG}.tar.gz" "$ARCHIVE"
    msg_skip "No checksum for a branch build (${TAG}); use a release for normal installs"
  fi
  mkdir src
  tar -xzf "$ARCHIVE" -C src --strip-components=1 || msg_err "Cannot extract ${ARCHIVE}."
fi

for f in "${REQUIRED_FILES[@]}"; do
  [[ -f "src/$f" ]] || msg_err "Archive is missing ${f}."
done
[[ -f src/VERSION ]] || echo "${TAG}" > src/VERSION
msg_ok "All files present"

# =============================================================
echo; echo "${DIM}  Install${CL}"
# =============================================================
chmod 755 "src/${NAME}"
rm -rf "${LIB_DIR}.new"
mkdir -p "$(dirname "$LIB_DIR")"
cp -a src "${LIB_DIR}.new"
chown -R root:root "${LIB_DIR}.new"
if [[ -d "$LIB_DIR" ]]; then rm -rf "${LIB_DIR}.old"; mv "$LIB_DIR" "${LIB_DIR}.old"; fi
mv "${LIB_DIR}.new" "$LIB_DIR"
rm -rf "${LIB_DIR}.old"
ln -sfn "${LIB_DIR}/${NAME}" "$BIN_LINK"
msg_ok "Installed ${LIB_DIR} ($(cat "${LIB_DIR}/VERSION"))"
msg_ok "Linked ${BIN_LINK}"
cd /

echo
echo "  Next: ${BL}dsokube up <cluster>${CL}   (inventory from ${BL}dsonode inventory <set>${CL}, or -i <file>)"
