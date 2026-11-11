[English](README.md) | **한국어**

# dsokube

이미 있는 머신에 공식 [k3s-ansible](https://github.com/k3s-io/k3s-ansible)로 K3s를 올립니다. dsokube는 버전을 고정하고, 조인 토큰을 보관하고, 실행 전에 inventory를 점검하고, 실행한 머신에 kubeconfig를 남겨 줍니다.

```bash
dsokube up kube       # dsonode 묶음 "kube"의 노드에 K3s 설치
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
│   ├── token          조인 토큰, 한 번만 만듦 (600)
│   └── kubeconfig     서버 https://10.73.41.11:6443, 컨텍스트 "kube" (600)
└── collections/       고정된 버전의 k3s-ansible과 ansible.utils
```

그룹 이름은 k3s-ansible이 쓰는 그대로입니다. 모든 노드는 `k3s_cluster`, 컨트롤 플레인(마스터)은 `server`, 워커는 `agent`입니다. dsonode라면 `roles`에 적으면 됩니다.

```yaml
nodes:
  cp1: { type: vm, host: 11, memory: 4096, roles: [k3s_cluster, server] }
  w1:  { type: vm, host: 21, roles: [k3s_cluster, agent] }
```

서버 한 대만 있어도 클러스터로 동작합니다. K3s는 서버에도 워크로드를 올리니까요. 워커는 나중에 붙여도 되고, 서버를 세 대로 늘리면 HA 컨트롤 플레인이 됩니다.

## k3s-ansible에 더해 주는 것

플레이북을 돌리기 전에 확인합니다.

- ansible-core가 2.15 이상인지 (k3s-ansible이 요구하는 최소 버전)
- `server` 그룹이 비어 있지 않은지. 서버가 짝수면 경고합니다(etcd는 1, 3, 5대를 원함)
- `k3s_cluster`에 LXC가 섞여 있지 않은지 (dsonode가 호스트마다 `dsonode_type`을 붙여 줌)
- `kubectl`이 있는지. 없으면 받아서 sha256을 확인한 뒤 설치합니다
- k3s-ansible이 고정된 버전인지, 그리고 `ansible.utils`와 Python `netaddr`가 있는지. 둘 다 워커를 붙일 때 필요한데 k3s-ansible이 알아서 깔아 주지 않습니다
- 조인 토큰. 한 번 만들어 다시 쓰니, 다시 실행해도 토큰이 바뀌지 않습니다

플레이북에는 `k3s_version`, `token`, `api_endpoint`(첫 번째 서버)를 넘깁니다. 끝나면 k3s-ansible이 kubeconfig를 돌려주지 않은 경우 직접 가져오고, 주소를 첫 번째 서버로 바꾸고, 클러스터·사용자·컨텍스트 이름을 클러스터 이름으로 바꿉니다.

## 요구사항

- dsokube를 돌릴 머신에 bash, curl, jq, ansible-core 2.15 이상, 노드로의 SSH 접속
- 노드: k3s-ansible이 지원하는 VM. Proxmox VE 8.4 위에서 dsonode로 만든 Debian 12 VM으로 확인했습니다.
- 노드에서 인터넷 접속 (K3s 설치 스크립트와 이미지)

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
| `dsokube up <cluster> [-i INVENTORY]` | K3s 설치 또는 갱신. 다시 실행해도 안전하고, inventory에 추가된 워커가 붙습니다 |
| `dsokube status <cluster>` | 노드와 파드 |
| `dsokube ctx <cluster>` | `~/.kube/config`가 이 클러스터를 가리키게 함 (원래 파일은 먼저 옆으로 옮김) |
| `dsokube down <cluster> [-y]` | k3s-ansible의 reset 플레이북으로 K3s 제거. 머신은 그대로 남음 |

`-i`가 없으면 inventory는 `dsonode inventory <cluster>`에서 가져옵니다. `-i`를 쓰면 `<cluster>`는 폴더와 컨텍스트 이름으로만 씁니다.

## 버전

[`versions.env`](versions.env):

```
K3S_VERSION=v1.36.5+k3s1
K3S_ANSIBLE_VERSION=1.2.2
KUBECTL_VERSION=v1.36.5
```

파일을 고치거나, 한 번만 다르게 돌리려면 앞에 적으면 됩니다: `K3S_VERSION=v1.36.6+k3s1 dsokube up kube`

## 알려진 제약

- K3s 자체는 k3s-ansible 방식대로 `get.k3s.io` 설치 스크립트로 설치됩니다. dsokube는 이 스크립트를 검증하지 않습니다.
- VIP가 없습니다. 워커와 kubeconfig는 첫 번째 서버를 씁니다. 서버가 세 대면 한 대가 죽어도 클러스터는 버티지만, 새 노드가 붙거나 kubeconfig로 접속할 때는 여전히 첫 번째 서버가 필요합니다.
- k3s-ansible이 같이 깔아 주는 `community.general`이 "ansible-core 2.17을 지원하지 않는다"는 경고를 냅니다. 여기서 쓰는 기능은 다 돌아가고, 맞는 버전으로 고정하는 건 할 일 목록에 있습니다.
- RKE2는 아직 없습니다.

## 고마운 분들

K3s를 설치하는 일은 전부 [k3s-io/k3s-ansible](https://github.com/k3s-io/k3s-ansible)이 합니다. dsokube는 실행 준비와 뒷정리만 합니다.

## 라이선스

Apache-2.0. [LICENSE](LICENSE)를 보세요.
