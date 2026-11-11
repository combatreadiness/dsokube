**English** | [한국어](README.ko.md)

# dsokube

K3s on machines you already have, through the official [k3s-ansible](https://github.com/k3s-io/k3s-ansible). dsokube pins the versions, keeps the join token, checks the inventory before anything runs, and gives you a kubeconfig on the machine you run it from.

```bash
dsokube up kube       # K3s on the nodes of dsonode set "kube"
dsokube ctx kube      # ~/.kube/config -> this cluster
kubectl get nodes
```

The machines come from [dsonode](https://github.com/combatreadiness/dsonode), or from any Ansible inventory you already have (`-i`).

## What you get

```
dsonode set "kube"                         K3s v1.36.5+k3s1
├── cp1  10.73.41.11  [k3s_cluster, server]  -> control plane, embedded etcd
└── w1   10.73.41.21  [k3s_cluster, agent]   -> worker

~/.config/dsokube/
├── kube/
│   ├── token          join token, made once (600)
│   └── kubeconfig     server https://10.73.41.11:6443, context "kube" (600)
└── collections/       the pinned k3s-ansible and ansible.utils
```

The group names are k3s-ansible's own: `k3s_cluster` for every node, `server` for the control plane, `agent` for workers. With dsonode, put them in `roles`:

```yaml
nodes:
  cp1: { type: vm, host: 11, memory: 4096, roles: [k3s_cluster, server] }
  w1:  { type: vm, host: 21, roles: [k3s_cluster, agent] }
```

One server alone is a working cluster: K3s schedules workloads on it. Add agents later, or go to three servers for an HA control plane.

## What dsokube adds to k3s-ansible

Before it runs the playbook:

- ansible-core is 2.15 or newer (k3s-ansible's own minimum)
- the `server` group is not empty; an even number of servers gets a warning (etcd wants 1, 3, 5)
- no LXC in `k3s_cluster` (dsonode marks each host with `dsonode_type`)
- `kubectl` is there, else it downloads it and checks the sha256
- k3s-ansible at the pinned version, plus `ansible.utils` and Python `netaddr`, which k3s-ansible needs for agents but does not pull in by itself
- a join token, created once and reused, so running again does not rotate it

It passes `k3s_version`, `token` and `api_endpoint` (the first server) to the playbook. Afterwards it fetches the kubeconfig if k3s-ansible did not, points it at the first server and names the cluster, user and context after the cluster.

## Requirements

- On the machine that runs dsokube: bash, curl, jq, ansible-core 2.15+, SSH access to the nodes.
- Nodes: VMs that k3s-ansible supports. Tested on Debian 12 VMs from dsonode on Proxmox VE 8.4.
- Internet from the nodes (the K3s install script and images).

On a proxmox-iac-bootstrap v0.1.4 management node, Debian 12 ships ansible-core 2.14. Put a newer one next to it:

```bash
apt-get install -y python3-venv
python3 -m venv /opt/ansible
/opt/ansible/bin/pip install 'ansible-core>=2.17,<2.18'
for b in ansible ansible-playbook ansible-galaxy ansible-inventory; do ln -sf /opt/ansible/bin/$b /usr/local/bin/$b; done
```

## Install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/dsokube/main/install.sh)"
```

## Commands

| Command | What it does |
|---|---|
| `dsokube up <cluster> [-i INVENTORY]` | Install or update K3s. Safe to run again; agents added to the inventory join |
| `dsokube status <cluster>` | Nodes and pods |
| `dsokube ctx <cluster>` | Point `~/.kube/config` at this cluster (an existing file is moved aside first) |
| `dsokube down <cluster> [-y]` | Uninstall K3s with k3s-ansible's reset playbook. The machines stay |

Without `-i`, the inventory comes from `dsonode inventory <cluster>`. With `-i`, `<cluster>` only names the folder and the context.

## Versions

[`versions.env`](versions.env):

```
K3S_VERSION=v1.36.5+k3s1
K3S_ANSIBLE_VERSION=1.2.2
KUBECTL_VERSION=v1.36.5
```

Change the file, or set one for a single run: `K3S_VERSION=v1.36.6+k3s1 dsokube up kube`.

## Known limitations

- K3s itself is installed the way k3s-ansible does it: through the `get.k3s.io` install script. dsokube does not verify that script.
- No VIP. Agents and the kubeconfig use the first server. With three servers the cluster survives losing one, but new joins and your kubeconfig still need it.
- `community.general` (pulled in by k3s-ansible) warns that it does not support ansible-core 2.17. Everything used here runs; pinning a matching version is on the list.
- RKE2 is not there yet.

## Thanks

All the K3s work is [k3s-io/k3s-ansible](https://github.com/k3s-io/k3s-ansible). dsokube only prepares the run and tidies up after it.

## License

Apache-2.0. See [LICENSE](LICENSE).
