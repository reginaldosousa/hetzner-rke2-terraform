# hetzner-cloud

RKE2 Kubernetes cluster on Hetzner Cloud:

- 3 RKE2 server (control-plane + etcd) nodes managed by Terraform
- Worker nodes provisioned on demand by [Karpenter](https://karpenter.sh) using the
  community [Hetzner provider](https://github.com/stubbi/karpenter-provider-hetzner)
- A private network — **no cluster node has a public IP**
- A WireGuard gateway as the only public host (VPN entry + NAT for egress)

The git history builds the project one piece at a time — `git log --reverse -p` reads like a walkthrough.

## Architecture

```
laptop ──WireGuard udp/51820──► gateway  (public IP; firewall: only 51820/udp)
                                  │ wg0 10.200.0.1, IP forwarding, nftables NAT
        hcloud network 10.0.0.0/16 ── subnet 10.0.1.0/24
          routes: 0.0.0.0/0 → gateway (egress), 10.200.0.0/24 → gateway (VPN return)
          ├── 10.0.1.2      gateway
          ├── 10.0.1.10     private LB  :6443 kube-apiserver, :9345 RKE2 join
          ├── 10.0.1.11-13  master-1..3   (private only, spread placement group)
          └── 10.0.1.x      Karpenter workers (private only, Ubuntu + rke2-agent)
```

| Piece | Where |
|---|---|
| Network, routes | `terraform/infra/network.tf` |
| VPN/NAT gateway | `terraform/infra/gateway.tf`, `templates/gateway-cloud-init.yaml.tftpl` |
| Control-plane LB | `terraform/infra/loadbalancer.tf` |
| Masters, CCM + CSI | `terraform/infra/masters.tf`, `templates/master-cloud-init.yaml.tftpl` |
| Default route for private-only servers | `templates/private-network.sh.tftpl` |
| Worker bootstrap (Karpenter userData) | `templates/worker-userdata.yaml.tftpl` |
| Karpenter, NodeClass, NodePool | `terraform/cluster/` |

Two Terraform roots: `infra` talks only to the Hetzner API; `cluster` talks to
Kubernetes and therefore runs **over the VPN**.

## Prerequisites

`terraform` ≥ 1.6, `wireguard-tools` (or the WireGuard app), `jq`, `kubectl`, `helm`,
a Hetzner Cloud project and a **read/write** API token.

## Bootstrap

```bash
# 1. Infrastructure
cd terraform/infra
cp terraform.tfvars.example terraform.tfvars   # set hcloud_token + ssh_public_key
terraform init && terraform apply

# 2. VPN
mkdir -p ../../wg
terraform output -json vpn_client_configs | jq -r .laptop > ../../wg/laptop.conf
sudo wg-quick up ../../wg/laptop.conf          # or import into the WireGuard app
ping 10.0.1.11

# 3. Kubeconfig (waits for RKE2 to come up)
../../scripts/get-kubeconfig.sh
export KUBECONFIG=$PWD/../../kubeconfig
kubectl get nodes                               # 3 masters, NotReady/uninitialized is expected

# 4. In-cluster: hcloud secret (unblocks CCM/CSI), Karpenter, NodePool
cd ../cluster
terraform init && terraform apply
```

After step 4 the CCM initialises the masters (`spec.providerID: hcloud://…`) and
Karpenter starts serving pending pods.

## Verify

```bash
kubectl get nodes -o wide                       # masters Ready, INTERNAL-IP only
kubectl get nodes -o jsonpath='{.items[*].spec.providerID}'
kubectl get hcloudnodeclass default             # READY=True

# Scale-up test
kubectl create deployment inflate --image=registry.k8s.io/pause:3.10 --replicas=5
kubectl set resources deployment inflate --requests=cpu=1
kubectl get nodeclaims -w                       # new servers appear and join

# Scale-down test
kubectl delete deployment inflate               # consolidation removes the workers after ~1m
```

From outside the VPN only `udp/51820` on the gateway should answer.

## Operations

- **SSH**: only over the VPN — `ssh root@10.0.1.11` (masters), `ssh root@10.0.1.2` (gateway).
- **Upgrading RKE2**: bump `rke2_version`. Masters ignore user_data changes (no
  accidental rebuilds), so upgrade them in place (e.g. system-upgrade-controller).
  New workers pick up the new version from the userData; existing ones are replaced
  as Karpenter drifts/consolidates them.
- **Upgrading the Karpenter chart**: Helm does not update CRDs — apply them first
  (see the provider README).
- **Adding VPN users**: add a name to `vpn_clients` and re-apply. Note this changes
  the gateway's user_data and therefore **recreates the gateway** (brief VPN + egress
  outage, new public IP).

## Security notes

- Terraform state contains the RKE2 tokens, WireGuard private keys and the Hetzner
  token. It is git-ignored; move it to an encrypted remote backend before sharing.
- Workers join with a separate RKE2 **agent token**; the server token never leaves
  the masters. The Hetzner API token is never put in user_data.
- Worker userData (with the agent token) is still readable from the Hetzner metadata
  service (`169.254.169.254`). Consider a Calico `GlobalNetworkPolicy` that blocks pod
  egress to it.
- The gateway is a single point of failure for VPN and egress.

## Versions

| Component | Version |
|---|---|
| RKE2 | v1.36.5+rke2r1 |
| hcloud CCM chart | 1.39.2 |
| hcloud CSI chart | 2.24.1 |
| karpenter-provider-hetzner chart | 3.0.1 |
| Terraform hcloud provider | ~> 1.70 |

Server types default to `cx23` (gateway) and `cx33` (masters). Check what your
project offers with `hcloud server-type list` and override in `terraform.tfvars`.
