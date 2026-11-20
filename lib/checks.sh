# shellcheck shell=bash
# =============================================================
# lib/checks.sh — tools and inventory checks (sourced by dsokube)
# =============================================================

need_ansible() {
  local v
  command -v ansible-playbook >/dev/null || die "Ansible not found."
  v="$(ansible --version | sed -n '1s/.*core \([0-9.]*\).*/\1/p')"
  version_ge "$v" 2.15 || die "ansible-core ${v} is too old; dsokube needs 2.15 or newer."
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

# need_rke2_ansible  -> RKE2_ANSIBLE_DIR: the official rke2-ansible at the pinned tag, its commit checked
# (it is a playbook repository, not a galaxy collection)
need_rke2_ansible() {
  local url="https://github.com/ranchergovernment/rke2-ansible.git" tmp head
  RKE2_ANSIBLE_DIR="${DSOKUBE_HOME}/vendor/rke2-ansible-${RKE2_ANSIBLE_VERSION}"
  if [[ -d "${RKE2_ANSIBLE_DIR}/.git" ]] \
     && [[ "$(git -C "$RKE2_ANSIBLE_DIR" rev-parse HEAD 2>/dev/null)" == "$RKE2_ANSIBLE_COMMIT" ]]; then
    return 0
  fi
  command -v git >/dev/null || die "git not found (apt install git); it fetches rke2-ansible."
  install -d -m 700 "${DSOKUBE_HOME}/vendor"
  tmp="${RKE2_ANSIBLE_DIR}.tmp"
  rm -rf "$tmp"
  log "Fetching rke2-ansible ${RKE2_ANSIBLE_VERSION}"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$RKE2_ANSIBLE_VERSION" "$url" "$tmp" \
    || { rm -rf "$tmp"; die "Could not clone ${url} at ${RKE2_ANSIBLE_VERSION}"; }
  head="$(git -C "$tmp" rev-parse HEAD)"
  if [[ "$head" != "$RKE2_ANSIBLE_COMMIT" ]]; then
    rm -rf "$tmp"
    die "rke2-ansible ${RKE2_ANSIBLE_VERSION} is commit ${head}, expected ${RKE2_ANSIBLE_COMMIT}. Discarded."
  fi
  rm -rf "$RKE2_ANSIBLE_DIR"
  mv "$tmp" "$RKE2_ANSIBLE_DIR"
  log "Commit verified: ${head:0:12}"
}

# ansible_python  -> prints the Python that runs Ansible
ansible_python() {
  local py
  py="$(dirname "$(readlink -f "$(command -v ansible-playbook)")")/python3"
  [[ -x "$py" ]] || py="$(command -v python3)"
  echo "$py"
}

# check_rke2_cni <vars.yml>  -> stops when it turns the CNI off.
# rke2-ansible waits for the first server to be Ready and fails after five minutes,
# and a node without a CNI is never Ready. Pick one of RKE2's own instead (canal is the default).
check_rke2_cni() {
  [[ -f "$1" ]] || return 0
  local where
  where="$("$(ansible_python)" - "$1" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for k in ("cluster_rke2_config", "group_rke2_config", "host_rke2_config"):
    c = d.get(k) or {}
    if isinstance(c, str):
        c = yaml.safe_load(c) or {}
    cni = c.get("cni") if isinstance(c, dict) else None
    if any(str(v).lower() == "none" for v in (cni if isinstance(cni, list) else [cni]) if v is not None):
        print(k)
        break
EOF
)" || die "Cannot read $1"
  [[ -z "$where" ]] || die "cni: none in ${where} (${1}). RKE2 needs a CNI: leave it out for Canal, or use cilium or calico."
}

# need_netaddr  -> the netaddr Python library, in the Python that runs Ansible (ipwrap needs it)
need_netaddr() {
  local py
  py="$(ansible_python)"
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

# check_inventory <inventory>
#   -> DISTRO (k3s | rke2) and DISTRO_LABEL from the groups the inventory uses, SERVER_GROUP, AGENT_GROUP,
#      NODE_COUNT, API_ENDPOINT. Stops on no servers, both kinds of groups, or LXC nodes.
#   K3s : k3s_cluster, server, agent                (k3s-ansible)
#   RKE2: rke2_cluster, rke2_servers, rke2_agents   (rke2-ansible)
check_inventory() {
  local inv json k3s rke2 servers agents lxc
  inv="$1"
  json="$(ansible-inventory -i "$inv" --list 2>/dev/null)" || die "Cannot read inventory ${inv}"
  # ansible-inventory --list keeps hosts in the group that names them, so count server groups
  k3s="$(jq -r '.server.hosts // [] | length' <<<"$json")"
  rke2="$(jq -r '.rke2_servers.hosts // [] | length' <<<"$json")"
  # shellcheck disable=SC2034  # DISTRO is read by dsokube
  if [[ "$k3s" -ge 1 && "$rke2" -ge 1 ]]; then
    die "The inventory has both 'server' (K3s) and 'rke2_servers' (RKE2). One cluster, one kind."
  elif [[ "$rke2" -ge 1 ]]; then
    DISTRO=rke2; DISTRO_LABEL=RKE2; SERVER_GROUP=rke2_servers; AGENT_GROUP=rke2_agents
  elif [[ "$k3s" -ge 1 ]]; then
    DISTRO=k3s; DISTRO_LABEL=K3s; SERVER_GROUP=server; AGENT_GROUP=agent
  else
    die "No server. Give at least one node roles: [k3s_cluster, server] (K3s) or [rke2_cluster, rke2_servers] (RKE2)."
  fi
  servers="$(jq -r --arg g "$SERVER_GROUP" '.[$g].hosts // [] | length' <<<"$json")"
  agents="$(jq -r --arg g "$AGENT_GROUP" '.[$g].hosts // [] | length' <<<"$json")"
  # shellcheck disable=SC2034  # read by dsokube (up_rke2)
  NODE_COUNT=$((servers + agents))
  if [[ "$servers" -gt 1 && $((servers % 2)) -eq 0 ]]; then
    warn "${servers} servers: etcd wants an odd number (1, 3, 5)."
  fi
  lxc="$(jq -r --arg s "$SERVER_GROUP" --arg a "$AGENT_GROUP" \
    '[((.[$s].hosts // []) + (.[$a].hosts // []))[] as $h | select(._meta.hostvars[$h].dsonode_type == "lxc") | $h] | join(", ")' <<<"$json")"
  [[ -z "$lxc" ]] || die "LXC nodes in ${SERVER_GROUP}/${AGENT_GROUP} (${lxc}). Kubernetes goes on VMs only."
  API_ENDPOINT="$(jq -r --arg g "$SERVER_GROUP" '._meta.hostvars[.[$g].hosts[0]].ansible_host // .[$g].hosts[0]' <<<"$json")"
  log "Inventory: ${DISTRO_LABEL}, ${servers} server(s), ${agents} agent(s), API ${API_ENDPOINT}"
}
