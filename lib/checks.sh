# shellcheck shell=bash
# =============================================================
# lib/checks.sh — tools and inventory checks (sourced by dsokube)
# =============================================================

need_ansible() {
  local v
  command -v ansible-playbook >/dev/null || die "Ansible not found."
  v="$(ansible --version | sed -n '1s/.*core \([0-9.]*\).*/\1/p')"
  version_ge "$v" 2.15 || die "ansible-core ${v} is too old; k3s-ansible needs 2.15 or newer."
  command -v jq >/dev/null || die "jq not found (apt install jq)."
}

# need_collection  -> the pinned k3s-ansible, in dsokube's own collections path
need_collection() {
  export ANSIBLE_COLLECTIONS_PATH="${DSOKUBE_HOME}/collections"
  local have
  have="$(ansible-galaxy collection list k3s.orchestration -p "$ANSIBLE_COLLECTIONS_PATH" 2>/dev/null \
          | awk '$1 == "k3s.orchestration" {print $2}' || true)"
  if [[ "$have" != "$K3S_ANSIBLE_VERSION" ]]; then
    log "Installing k3s-ansible ${K3S_ANSIBLE_VERSION}"
    ansible-galaxy collection install --force -p "$ANSIBLE_COLLECTIONS_PATH" \
      "git+https://github.com/k3s-io/k3s-ansible.git,${K3S_ANSIBLE_VERSION}" >/dev/null
  fi
  # k3s-ansible needs ansible.utils (ipwrap) but does not list it in galaxy.yml
  if ! ansible-galaxy collection list ansible.utils -p "$ANSIBLE_COLLECTIONS_PATH" 2>/dev/null | grep -q '^ansible\.utils '; then
    log "Installing ansible.utils"
    ansible-galaxy collection install -p "$ANSIBLE_COLLECTIONS_PATH" ansible.utils >/dev/null
  fi
  need_netaddr
}

# need_netaddr  -> the netaddr Python library, in the Python that runs Ansible (ipwrap needs it)
need_netaddr() {
  local py
  py="$(dirname "$(readlink -f "$(command -v ansible-playbook)")")/python3"
  [[ -x "$py" ]] || py="$(command -v python3)"
  "$py" -c 'import netaddr' 2>/dev/null && return 0
  if [[ -x "$(dirname "$py")/pip" ]]; then
    log "Installing netaddr for ${py}"
    "$(dirname "$py")/pip" install --quiet netaddr
  else
    die "Python netaddr missing for Ansible (${py}). Install it: apt install python3-netaddr"
  fi
}

# need_kubectl  -> kubectl on this machine (k3s-ansible only copies the kubeconfig back when it exists)
need_kubectl() {
  command -v kubectl >/dev/null && return 0
  local url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" tmp
  tmp="$(mktemp -d)"
  log "Installing kubectl ${KUBECTL_VERSION}"
  curl -fsSL "$url" -o "${tmp}/kubectl"
  echo "$(curl -fsSL "${url}.sha256")  ${tmp}/kubectl" | sha256sum -c --status \
    || { rm -rf "$tmp"; die "kubectl checksum mismatch. Download discarded."; }
  install -m 755 "${tmp}/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
  log "Checksum verified: /usr/local/bin/kubectl"
}

# check_inventory <inventory>  -> sets API_ENDPOINT; stops on an empty server group or LXC nodes
check_inventory() {
  local inv json servers lxc
  inv="$1"
  json="$(ansible-inventory -i "$inv" --list 2>/dev/null)" || die "Cannot read inventory ${inv}"
  servers="$(jq -r '.server.hosts // [] | length' <<<"$json")"
  [[ "$servers" -ge 1 ]] || die "No host in group 'server'. Give at least one node roles: [k3s_cluster, server]."
  if [[ "$servers" -gt 1 && $((servers % 2)) -eq 0 ]]; then
    warn "${servers} servers: etcd wants an odd number (1, 3, 5)."
  fi
  lxc="$(jq -r '[(.k3s_cluster.hosts // [])[] as $h | select(._meta.hostvars[$h].dsonode_type == "lxc") | $h] | join(", ")' <<<"$json")"
  [[ -z "$lxc" ]] || die "LXC nodes in k3s_cluster (${lxc}). Kubernetes goes on VMs only."
  API_ENDPOINT="$(jq -r '._meta.hostvars[.server.hosts[0]].ansible_host // .server.hosts[0]' <<<"$json")"
  log "Inventory: ${servers} server(s), $(jq -r '.agent.hosts // [] | length' <<<"$json") agent(s), API ${API_ENDPOINT}"
}
