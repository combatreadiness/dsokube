[English](README.md) | **한국어**

# dsokube

이미 있는 머신에 공식 [k3s-ansible](https://github.com/k3s-io/k3s-ansible)이나 [rke2-ansible](https://github.com/ranchergovernment/rke2-ansible)로 K3s 또는 RKE2를 올립니다. dsokube는 버전을 고정하고, 실행 전에 inventory를 점검하고, 실행한 머신에 kubeconfig를 남겨 줍니다.

```bash
dsokube up kube       # dsonode 묶음 "kube"의 노드에 K3s 또는 RKE2 설치
dsokube ctx kube      # ~/.kube/config -> 이 클러스터
kubectl get nodes
```

머신은 [dsonode](https://github.com/combatreadiness/dsonode)로 만들어도 되고, 이미 가진 Ansible inventory를 써도 됩니다(`-i`).

## 무엇이 만들어지나

```
dsonode 묶음 "kube"                        K3s v1.36.5+k3s1
├── cp1  10.73.41.11  [k3s_cluster, server]  -> 컨트롤 플레인, 내장 etcd
└── w1   10.73.41.21  [k3s_cluster, agent]   -> 워커

~/.config/dsokube/
├── kube/
│   ├── token          K3s 조인 토큰, 한 번만 만듦 (600)
│   └── kubeconfig     서버 https://10.73.41.11:6443, 컨텍스트 "kube" (600)
├── collections/       고정된 버전의 k3s-ansible과 ansible.utils
└── vendor/            고정된 버전의 rke2-ansible
```

## K3s냐 RKE2냐

inventory의 그룹 이름으로 정해집니다. 각 플레이북이 쓰는 이름 그대로입니다.

| | 모든 노드 | 컨트롤 플레인 | 워커 |
|---|---|---|---|
| K3s | `k3s_cluster` | `server` | `agent` |
| RKE2 | `rke2_cluster` | `rke2_servers` | `rke2_agents` |

dsonode라면 `roles`에 적으면 됩니다.

```yaml
nodes:
  # K3s
  cp1: { type: vm, host: 11, memory: 4096, roles: [k3s_cluster, server] }
  w1:  { type: vm, host: 21, roles: [k3s_cluster, agent] }
```

```yaml
nodes:
  # RKE2: K3s보다 자원을 더 씁니다. 서버는 최소 4GB
  server1: { type: vm, host: 11, cores: 4, memory: 8192, disk: 40, roles: [rke2_cluster, rke2_servers] }
  agent1:  { type: vm, host: 21, cores: 2, memory: 4096, disk: 30, roles: [rke2_cluster, rke2_agents] }
```

서버 한 대만 있어도 클러스터로 동작합니다. 둘 다 서버에도 워크로드를 올리니까요. 워커는 나중에 붙여도 되고, 서버를 세 대로 늘리면 HA 컨트롤 플레인이 됩니다. 두 종류의 그룹이 섞인 inventory는 거절합니다.

## dsokube가 더해 주는 것

플레이북을 돌리기 전에 확인합니다.

- ansible-core가 2.15 이상인지
- 서버가 한 대 이상 있는지. 서버가 짝수면 경고합니다(etcd는 1, 3, 5대를 원함)
- 서버와 에이전트에 LXC가 섞여 있지 않은지 (dsonode가 호스트마다 `dsonode_type`을 붙여 줌)
- `kubectl`이 있는지. 없으면 받아서 sha256을 확인한 뒤 설치합니다

K3s일 때:

- k3s-ansible이 고정된 버전인지, 그리고 `ansible.utils`와 Python `netaddr`가 있는지. 둘 다 워커를 붙일 때 필요한데 k3s-ansible이 알아서 깔아 주지 않습니다
- 조인 토큰. 한 번 만들어 다시 쓰니, 다시 실행해도 토큰이 바뀌지 않습니다
- 플레이북에 `k3s_version`, `token`, `api_endpoint`(첫 번째 서버)를 넘기고, k3s-ansible이 kubeconfig를 돌려주지 않으면 직접 가져옵니다

RKE2일 때:

- rke2-ansible을 고정된 태그로 git clone합니다. 커밋이 `versions.env`에 적힌 것과 다르면 받은 것을 버립니다
- 이 플레이북은 넘겨받은 모든 호스트에서 돌고, 서버가 아닌 호스트는 전부 에이전트로 만듭니다. 그래서 dsokube가 `rke2_servers`와 `rke2_agents`로 범위를 좁힙니다. 같은 inventory의 다른 호스트는 건드리지 않습니다
- `rke2_install_version`을 넘깁니다. 조인 토큰은 rke2-ansible이 실행할 때마다 첫 번째 서버에서 읽어 씁니다
- kubeconfig는 매번 새로 가져옵니다. RKE2는 다시 설치하면 CA가 새로 만들어져서 예전 kubeconfig로는 접속이 안 됩니다
- 모든 노드가 등록되고 Ready가 될 때까지 기다립니다. 플레이북은 첫 번째 서버만 기다립니다

어느 쪽이든 kubeconfig는 첫 번째 서버를 가리키고, 클러스터·사용자·컨텍스트 이름은 클러스터 이름으로 바꿉니다.

## 요구사항

- dsokube를 돌릴 머신에 bash, curl, jq, git, ansible-core 2.15 이상, 노드로의 SSH 접속
- 노드: VM. Proxmox VE 8.4 위에서 dsonode로 만든 Debian 12 VM으로 K3s와 RKE2 모두 확인했습니다. rke2-ansible의 지원 목록은 Rocky, RHEL, Ubuntu인데, Debian에서는 tarball 방식으로 설치되고 그대로 동작했습니다.
- 노드에서 인터넷 접속 (설치 스크립트나 tarball, 이미지)

proxmox-iac-bootstrap v0.1.4 관리 노드는 Debian 12라서 ansible-core 2.14가 깔려 있습니다. 새 버전을 옆에 따로 넣어 주세요.

```bash
apt-get install -y python3-venv
python3 -m venv /opt/ansible
/opt/ansible/bin/pip install 'ansible-core>=2.17,<2.18'
for b in ansible ansible-playbook ansible-galaxy ansible-inventory; do ln -sf /opt/ansible/bin/$b /usr/local/bin/$b; done
```

## 설치

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/dsokube/main/install.sh)"
```

## 명령

| 명령 | 하는 일 |
|---|---|
| `dsokube up <cluster> [-i INVENTORY]` | K3s나 RKE2 설치 또는 갱신. 다시 실행해도 안전하고, inventory에 추가된 워커가 붙습니다 |
| `dsokube status <cluster>` | 노드와 파드 |
| `dsokube ctx <cluster>` | `~/.kube/config`가 이 클러스터를 가리키게 함 (원래 파일은 먼저 옆으로 옮김) |
| `dsokube down <cluster> [-y]` | 쿠버네티스 제거. K3s는 k3s-ansible의 reset 플레이북, RKE2는 에이전트 → 서버 순서로 `rke2-uninstall.sh`. 머신은 그대로 남음 |

`-i`가 없으면 inventory는 `dsonode inventory <cluster>`에서 가져옵니다. `-i`를 쓰면 `<cluster>`는 폴더와 컨텍스트 이름으로만 씁니다.

## vars.yml

클러스터 설정을 바꾸려면 `~/.config/dsokube/<cluster>/vars.yml`에 플레이북 변수를 그대로 적으면 됩니다. `up`할 때마다 이 파일을 넘기니, 다시 돌려도 설정이 유지됩니다. dsokube가 넘기는 버전 값이 이 파일보다 우선합니다.

K3s 기본 네트워크를 끄고 Cilium 같은 CNI를 직접 깔려면:

```yaml
server_config_yaml: |
  flannel-backend: none
  disable-network-policy: true
```

RKE2는 `cluster_rke2_config`(모든 노드), `group_rke2_config`, `host_rke2_config`로 설정하고, 이 값이 `/etc/rancher/rke2/config.yaml`에 들어갑니다. 예를 들어 Canal 대신 RKE2에 내장된 Cilium을 쓰려면:

```yaml
cluster_rke2_config:
  cni: [cilium]
```

K3s에서 `flannel-backend: none`을 쓰면 CNI를 설치하기 전까지 노드는 `NotReady`로 남습니다. RKE2에는 항상 CNI가 들어갑니다. 따로 고르지 않으면 Canal이고, `cilium`이나 `calico`를 고를 수 있습니다. `cni: none`이면 `dsokube up`이 아무것도 실행하지 않고 멈춥니다. rke2-ansible이 첫 서버가 5분 안에 Ready가 되지 않으면 실패하기 때문입니다.

## 버전

[`versions.env`](versions.env):

```
K3S_VERSION=v1.36.5+k3s1
K3S_ANSIBLE_VERSION=1.2.2
KUBECTL_VERSION=v1.36.5
RKE2_VERSION=v1.36.6+rke2r1
RKE2_ANSIBLE_VERSION=v2.1.0
RKE2_ANSIBLE_COMMIT=76ff1c4c40155fe50133c8a25f9745005b8884a2
```

파일을 고치거나, 한 번만 다르게 돌리려면 앞에 적으면 됩니다: `K3S_VERSION=v1.36.6+k3s1 dsokube up kube`. `RKE2_ANSIBLE_VERSION`을 바꾸면 `RKE2_ANSIBLE_COMMIT`도 같이 바꿔야 합니다.

## 알려진 제약

- K3s는 k3s-ansible 방식대로 `get.k3s.io` 설치 스크립트로, RKE2는 rke2-ansible 방식대로 설치됩니다. dsokube는 이들이 내려받는 것을 검증하지 않습니다.
- VIP가 없습니다. 워커와 kubeconfig는 첫 번째 서버를 씁니다. 서버가 세 대면 한 대가 죽어도 클러스터는 버티지만, 새 노드가 붙거나 kubeconfig로 접속할 때는 여전히 첫 번째 서버가 필요합니다.
- k3s-ansible이 같이 깔아 주는 `community.general`이 "ansible-core 2.17을 지원하지 않는다"는 경고를 냅니다. 여기서 쓰는 기능은 다 돌아가고, 맞는 버전으로 고정하는 건 할 일 목록에 있습니다.
- RKE2 `down` 뒤에는 빈 `/opt/cni`와 `/run/k3s`의 containerd 소켓 파일이 남습니다(재부팅하면 사라짐). 같은 머신에 다시 `up`해도 문제없습니다.
- RKE2 서버 세 대 구성은 아직 시험하지 않았습니다.
- `dsonode new --servers --agents`는 K3s 그룹 이름을 씁니다. RKE2라면 위처럼 바꿔 주세요.

## 고마운 분들

쿠버네티스를 설치하는 일은 전부 [k3s-io/k3s-ansible](https://github.com/k3s-io/k3s-ansible)과 [ranchergovernment/rke2-ansible](https://github.com/ranchergovernment/rke2-ansible)이 합니다. dsokube는 실행 준비와 뒷정리만 합니다.

## 라이선스

Apache-2.0. [LICENSE](LICENSE)를 보세요.
