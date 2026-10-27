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
laptop ──WireGuard udp/51820──► gateway  (reserved public IP; firewall: only 51820/udp)
                                  │ wg0 10.200.0.1, IP forwarding, nftables NAT
        hcloud network 10.0.0.0/16 ── subnet 10.0.1.0/24
          routes: 0.0.0.0/0 → gateway (egress), 10.200.0.0/24 → gateway (VPN return)
          ├── 10.0.1.2      gateway + HAProxy :6443 kube-apiserver, :9345 RKE2 join
          ├── 10.0.1.11-13  master-1..3   (private only, spread placement group)
          └── 10.0.1.x      Karpenter workers (private only, Ubuntu + rke2-agent)
```

| Piece | Where |
|---|---|
| Network, routes | `terraform/infra/network.tf` |
| VPN/NAT gateway | `terraform/infra/gateway.tf`, `templates/gateway-cloud-init.yaml.tftpl` |
| Control-plane endpoint (HAProxy) | `templates/gateway-cloud-init.yaml.tftpl` |
| Masters, CCM + CSI | `terraform/infra/masters.tf`, `templates/master-cloud-init.yaml.tftpl` |
| Default route for private-only servers | `templates/private-network.sh.tftpl` |
| Worker bootstrap (Karpenter userData) | `templates/worker-userdata.yaml.tftpl` |
| Karpenter, NodeClass, NodePool | `terraform/cluster/` |

Two Terraform roots: `infra` talks only to the Hetzner API; `cluster` talks to
Kubernetes and therefore runs **over the VPN**.

## Prerequisites

`terraform` ≥ 1.10, `wireguard-tools` (or the WireGuard app), `jq`, `kubectl`, `helm`,
`aws` CLI, a Hetzner Cloud project and a **read/write** API token.

**Remote state** lives in the Cloudflare R2 bucket `rke2-tfstate` (S3 backend,
locking via `use_lockfile`; see `terraform/*/backend.tf`). Create an R2 API token
with **Object Read & Write scoped to that bucket only**, then:

```bash
aws configure --profile r2     # access key + secret of the R2 token, region "auto"
```

## Bootstrap

```bash
# 1. Infrastructure
cd terraform/infra
cp terraform.tfvars.example terraform.tfvars   # set hcloud_token + ssh_public_key
terraform init && terraform apply -var gateway_sync=false   # first apply only: no VPN yet

# 2. VPN
mkdir -p ../../wg
terraform output -json vpn_client_configs | jq -r .laptop > ../../wg/laptop.conf
sudo wg-quick up ../../wg/laptop.conf          # or import into the WireGuard app
ping 10.0.1.11
( cd terraform/infra && terraform apply )   # enables the fail-closed gateway sync

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

## Public ingress

RKE2's bundled Traefik is exposed through a public Hetzner Load Balancer
(lb11, ~€7.89/mo) that the hcloud CCM creates from the Traefik Service
(`terraform/cluster/ingress.tf`). The LB reaches Traefik over the private
network and uses PROXY protocol with `externalTrafficPolicy: Local`, so apps
see real client IPs.

```bash
kubectl apply -f examples/whoami.yaml
IP=$(kubectl -n kube-system get svc rke2-traefik -o jsonpath='{.status.loadBalancer.ingress[2].ip}')
curl http://$IP/                     # echoes the request, incl. X-Real-Ip
```

Point DNS at that IP. Traefik serves a self-signed cert until you add TLS
(e.g. cert-manager).

> The ingress LB is created by the CCM, **not by Terraform**. Before destroying
> the cluster, delete it (`kubectl -n kube-system delete svc rke2-traefik`, or
> delete the `rke2-ingress` LB in the Hetzner console), or it keeps billing.

## Operations

- **SSH**: only over the VPN — `ssh root@10.0.1.11` (masters), `ssh root@10.0.1.2` (gateway).
- **Protection**: the masters (etcd), the reserved gateway IP and the network have
  Hetzner delete/rebuild protection (`protect = true`). The API refuses deletes even
  from the console. A plan still *shows* the destroy; the apply fails. To replace or
  destroy them on purpose: set `protect = false`, apply (in-place), do the change,
  then set it back.
- **Upgrading RKE2**: bump `rke2_version`. Masters ignore user_data changes (no
  accidental rebuilds), so upgrade them in place (e.g. system-upgrade-controller).
  New workers pick up the new version from the userData; existing ones are replaced
  as Karpenter drifts/consolidates them.
- **Upgrading the Karpenter chart**: Helm does not update CRDs — apply them first
  (see the provider README).
- **Adding / removing VPN users**: edit `vpn_clients` (`name = <host number>`, e.g.
  `ci = 11` → 10.200.0.11) and `terraform apply`. Numbers are fixed, so removing a
  client never renumbers the others. Apply pushes the new peer list to the running
  gateway (`terraform_data.gateway_sync` → `scripts/sync-gateway.sh`). It validates
  on the gateway and then activates with `wg syncconf`, so tunnels stay up and the
  gateway is **not rebuilt**. This is **fail-closed**: if the push fails (VPN down,
  invalid config), the apply fails and the next apply retries, so a removed client
  can't silently keep access. Hand out a new client's config with
  `terraform output -json vpn_client_configs | jq -r .ci`.
- **Gateway config drift**: `scripts/sync-gateway.sh --dry-run` diffs the live
  gateway against Terraform (private keys redacted). A deliberate rebuild
  (`terraform apply -replace=hcloud_server.gateway`) also re-syncs.
- **Architecture**: everything runs on arm64 (`cax`), the cheapest orderable type.
  Workload images must be multi-arch (`docker buildx --platform linux/amd64,linux/arm64`).
  To use x86 workers instead, set `architectures`/`serverFamilies` in
  `terraform/cluster/charts/nodepools/values.yaml`.

## CI

`.github/workflows/terraform.yml` runs on every PR and on pushes to `main`. It
checks fmt and validate for both roots (with the committed lock files, read-only),
then runs tflint, trivy (HIGH/CRITICAL), `helm lint --strict` on the NodePool
chart, and shellcheck. Tool versions are pinned in the workflow's `env:`, and
actions are pinned to commit SHAs. CI never plans or applies against real
infrastructure: applies run locally over the VPN from a reviewed plan.

## Security notes

- Terraform state contains the RKE2 tokens, WireGuard and SSH host private keys
  and the Hetzner token. It lives in R2 (encrypted at rest by Cloudflare, but not
  client-side encrypted), so **anyone with the R2 token can read every secret**:
  keep the token scoped to the bucket and out of CI.
- **R2 has no object versioning.** Run `scripts/backup-state.sh` after each apply;
  it keeps the last 30 copies of each state in `state-backups/` (git-ignored).
  Restore with `terraform state push state-backups/<root>/<file>.tfstate`.
- Workers join with a separate RKE2 **agent token**; the server token never leaves
  the masters. The Hetzner API token is never put in user_data.
- Worker userData (with the agent token) is still readable from the Hetzner metadata
  service (`169.254.169.254`). Consider a Calico `GlobalNetworkPolicy` that blocks pod
  egress to it.
- The gateway is a single point of failure for VPN, egress and joining new nodes (HAProxy). Running nodes keep talking to the masters directly if it goes down.

## Versions

| Component | Version |
|---|---|
| RKE2 | v1.36.5+rke2r1 |
| hcloud CCM chart | 1.39.2 |
| hcloud CSI chart | 2.24.1 |
| karpenter-provider-hetzner chart | 3.0.1 |
| Terraform hcloud provider | ~> 1.70 |

Server types default to `cax11` (arm64, 2c/4GB) for the gateway and masters: the cheapest orderable type that is safe. Check what your
project offers with `hcloud server-type list` and override in `terraform.tfvars`.
