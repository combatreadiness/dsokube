**English** | [한국어](README.ko.md)

# dsokube

K3s or RKE2 on machines you already have, through the official [k3s-ansible](https://github.com/k3s-io/k3s-ansible) and [rke2-ansible](https://github.com/ranchergovernment/rke2-ansible). dsokube pins the versions, checks the inventory before anything runs, and gives you a kubeconfig on the machine you run it from.

```bash
dsokube up kube       # K3s or RKE2 on the nodes of dsonode set "kube"
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
│   ├── token          K3s join token, made once (600)
│   └── kubeconfig     server https://10.73.41.11:6443, context "kube" (600)
├── collections/       the pinned k3s-ansible and ansible.utils
└── vendor/            the pinned rke2-ansible
```

## K3s or RKE2

The groups in the inventory decide. They are each playbook's own names:

| | every node | control plane | workers |
|---|---|---|---|
| K3s | `k3s_cluster` | `server` | `agent` |
| RKE2 | `rke2_cluster` | `rke2_servers` | `rke2_agents` |

With dsonode, put them in `roles`:

```yaml
nodes:
  # K3s
  cp1: { type: vm, host: 11, memory: 4096, roles: [k3s_cluster, server] }
  w1:  { type: vm, host: 21, roles: [k3s_cluster, agent] }
```

```yaml
nodes:
  # RKE2: it wants more than K3s, at least 4 GB on a server
  server1: { type: vm, host: 11, cores: 4, memory: 8192, disk: 40, roles: [rke2_cluster, rke2_servers] }
  agent1:  { type: vm, host: 21, cores: 2, memory: 4096, disk: 30, roles: [rke2_cluster, rke2_agents] }
```

One server alone is a working cluster: both schedule workloads on servers. Add agents later, or go to three servers for an HA control plane. An inventory with both kinds of groups is refused.

## What dsokube adds

Before it runs a playbook:

- ansible-core is 2.15 or newer
- there is at least one server; an even number of servers gets a warning (etcd wants 1, 3, 5)
- no LXC among the servers and agents (dsonode marks each host with `dsonode_type`)
- `kubectl` is there, else it downloads it and checks the sha256

For K3s:

- k3s-ansible at the pinned version, plus `ansible.utils` and Python `netaddr`, which k3s-ansible needs for agents but does not pull in by itself
- a join token, created once and reused, so running again does not rotate it
- it passes `k3s_version`, `token` and `api_endpoint` (the first server), and fetches the kubeconfig if k3s-ansible did not

For RKE2:

- rke2-ansible at the pinned tag, cloned with git; its commit must match the one in `versions.env`, or the clone is thrown away
- the playbook runs on every host it is given and makes an agent of any host that is not a server, so dsokube limits it to `rke2_servers` and `rke2_agents`. Other hosts in the same inventory are left alone
- it passes `rke2_install_version`. The join token is rke2-ansible's: it reads it from the first server on every run
- it always fetches the kubeconfig again: an RKE2 reinstall makes a new CA, and an old kubeconfig stops working
- it waits until every node is registered and Ready. The playbook waits for the first server only

Either way, the kubeconfig points at the first server, and its cluster, user and context are named after the cluster.

## Requirements

- On the machine that runs dsokube: bash, curl, jq, git, ansible-core 2.15+, SSH access to the nodes.
- Nodes: VMs. Tested on Debian 12 VMs from dsonode on Proxmox VE 8.4, for both K3s and RKE2. rke2-ansible lists Rocky, RHEL and Ubuntu; on Debian it uses its tarball install, which worked as it is.
- Internet from the nodes (install scripts or tarballs, and images).

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
| `dsokube up <cluster> [-i INVENTORY]` | Install or update K3s or RKE2. Safe to run again; agents added to the inventory join |
| `dsokube status <cluster>` | Nodes and pods |
| `dsokube ctx <cluster>` | Point `~/.kube/config` at this cluster (an existing file is moved aside first) |
| `dsokube down <cluster> [-y]` | Uninstall Kubernetes. K3s: k3s-ansible's reset playbook. RKE2: `rke2-uninstall.sh` on agents, then servers. The machines stay |

Without `-i`, the inventory comes from `dsonode inventory <cluster>`. With `-i`, `<cluster>` only names the folder and the context.

## vars.yml

To change how the cluster is set up, put the playbook's own variables in `~/.config/dsokube/<cluster>/vars.yml`. `up` passes the file every time, so the setting stays on later runs. The versions dsokube passes still win.

K3s without its built-in network, for a CNI like Cilium:

```yaml
server_config_yaml: |
  flannel-backend: none
  disable-network-policy: true
```

RKE2 takes its settings as `cluster_rke2_config` (every node), `group_rke2_config` and `host_rke2_config`, written into `/etc/rancher/rke2/config.yaml`. For example, RKE2's own Cilium in place of Canal:

```yaml
cluster_rke2_config:
  cni: [cilium]
```

With `flannel-backend: none`, K3s nodes stay `NotReady` until you install a CNI. RKE2 always gets one: Canal unless you pick `cilium` or `calico`. `cni: none` stops `dsokube up` before anything runs, because rke2-ansible fails when the first server is not Ready in five minutes.

## Versions

[`versions.env`](versions.env):

```
K3S_VERSION=v1.36.5+k3s1
K3S_ANSIBLE_VERSION=1.2.2
KUBECTL_VERSION=v1.36.5
RKE2_VERSION=v1.36.6+rke2r1
RKE2_ANSIBLE_VERSION=v2.1.0
RKE2_ANSIBLE_COMMIT=76ff1c4c40155fe50133c8a25f9745005b8884a2
```

Change the file, or set one for a single run: `K3S_VERSION=v1.36.6+k3s1 dsokube up kube`. A new `RKE2_ANSIBLE_VERSION` needs its `RKE2_ANSIBLE_COMMIT` too.

## Known limitations

- K3s is installed the way k3s-ansible does it, through the `get.k3s.io` install script, and RKE2 the way rke2-ansible does it. dsokube does not verify what those download.
- No VIP. Agents and the kubeconfig use the first server. With three servers the cluster survives losing one, but new joins and your kubeconfig still need it.
- `community.general` (pulled in by k3s-ansible) warns that it does not support ansible-core 2.17. Everything used here runs; pinning a matching version is on the list.
- RKE2 `down` leaves an empty `/opt/cni` and containerd sockets under `/run/k3s` (gone at the next reboot). A later `up` on the same machines works.
- RKE2 with three servers has not been tested yet.
- `dsonode new --servers --agents` writes K3s roles. For RKE2, change them as shown above.

## Thanks

All the Kubernetes work is [k3s-io/k3s-ansible](https://github.com/k3s-io/k3s-ansible) and [ranchergovernment/rke2-ansible](https://github.com/ranchergovernment/rke2-ansible). dsokube only prepares the run and tidies up after it.

## License

Apache-2.0. See [LICENSE](LICENSE).
