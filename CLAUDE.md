# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform for an RKE2 Kubernetes cluster on Hetzner Cloud. It has 3 Terraform-managed masters, workers provisioned by Karpenter (community provider `stubbi/karpenter-provider-hetzner`), a private network where no cluster node has a public IP, and a WireGuard gateway as the only public host. README.md has the bootstrap steps and the architecture diagram. `docs/` explains the stack and holds the ADRs (`docs/adr/`). A new architectural decision gets a new ADR, and a reversed one is marked superseded rather than edited.

## Commands

There are no tests. Validation is static, and each change gets a render check:

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/infra validate     # needs `terraform init -backend=false` once
terraform -chdir=terraform/cluster validate
helm lint terraform/cluster/charts/nodepools
helm template t terraform/cluster/charts/nodepools --set networkID=12345678 --set sshKeyID=98765432
scripts/sync-gateway.sh --dry-run               # gateway drift vs. Terraform (needs VPN)
scripts/sync-masters.sh --dry-run               # masters' RKE2 config drift (needs VPN)
```

Render a cloud-init template to check the output. Run this from `terraform/infra`, passing the template's vars, and use `printf`, not zsh `echo`, which mangles `\n`. The dummy variables must pass the variables' validation rules:

```bash
printf '%s\n' 'templatefile("templates/worker-userdata.yaml.tftpl", {control_plane_ip="10.0.1.2", token="T", rke2_version="v", private_network_script="echo", rke2_install_url="u", rke2_install_sha256="s"})' \
  | terraform console -var hcloud_token="$(printf 'x%.0s' {1..64})" -var 'ssh_public_key=ssh-ed25519 AAAA'
```

## Architecture (cross-file facts)

- **Two Terraform roots, applied in order.**
  - `terraform/infra` talks only to the Hetzner API.
  - `terraform/cluster` talks to Kubernetes through `../../kubeconfig`, so it only works with the WireGuard tunnel up. It reads infra's outputs through `terraform_remote_state` from R2 (`infra/terraform.tfstate` in bucket `rke2-tfstate`). Both roots use the S3 backend against Cloudflare R2 with the `r2` AWS profile, and `use_lockfile` needs Terraform 1.10 or later. Changing the infra backend or its outputs breaks `cluster`. R2 has no versioning, so run `scripts/backup-state.sh` after applies.
- **Fixed private IPs** are computed with `cidrhost` in `network.tf` locals:
  - gateway `.2`, which is also the control-plane endpoint (`local.control_plane_ip`). There is no paid LB: HAProxy on the gateway forwards :6443 and :9345 to the masters. Only kubectl and joining nodes use it, because joined RKE2 agents load-balance across the masters themselves.
  - masters `.11` to `.13`. HAProxy's backend list is generated from `local.master_ips`.

  The router that private-only servers use as their default gateway is `cidrhost(network_cidr, 1)`. The hcloud network route `0.0.0.0/0 → gateway` then forwards their traffic to the NAT gateway.
- **`templates/private-network.sh.tftpl` is shared** by the master and worker cloud-init. It must run before anything downloads, because private-only servers have no default route until it does. Its result is embedded with `indent(6, …)`.
- **Bootstrap dependency.** The masters' cloud-init deploys the CCM and CSI HelmCharts, but the `kube-system/hcloud` Secret (API token and network ID) is created by `terraform/cluster`. Nodes stay `uninitialized` until that root is applied. Keep the API token out of user_data, because pods can read user_data from the metadata service.
- **Tokens.** Masters have both `token` and `agent-token`. Workers get only the agent token, through the `worker_user_data` output → Secret `karpenter-worker-bootstrap` → `HCloudNodeClass.userDataSecretRef`.
- **Karpenter contracts the worker userData must keep:**
  - the `karpenter.sh/unregistered=:NoExecute` taint
  - `cloud-provider-name: external`, so the CCM sets the `hcloud://` providerID
  - `kube-reserved` matching `spec.kubelet` in the NodeClass

  In the CCM, `HCLOUD_INSTANCES_ZONE_LABEL_ENABLED=false` leaves the zone label to Karpenter. Keep NodePools pinned to `capacity-type: on-demand`, because Hetzner has no spot capacity.
- **NodeClass and NodePool live in a local Helm chart** (`terraform/cluster/charts/nodepools`), because `kubernetes_manifest` can't plan before the Karpenter CRDs exist. Numeric IDs in its templates need `| int64`, or Helm renders them as `1.2e+07`. Bump `version` in its `Chart.yaml` on every template change: the helm provider only diffs values and chart version, so a template edit alone plans no change.
- **Masters and the gateway ignore `user_data` changes.** Editing the masters' template only affects newly built masters. The gateway's mutable files (`templates/gateway/*.tftpl` → `local.gateway_files`) reach the running gateway only through `scripts/sync-gateway.sh`, which validates on the gateway and then activates. `terraform_data.gateway_sync` runs it on every apply that changes those files, so applies need the VPN up, and a failed push fails the apply (fail-closed, so VPN revocation is enforced). The script reads `GATEWAY_FILES_JSON` from the environment because `terraform output` is stale during an apply. Use `-var gateway_sync=false` only for the very first bootstrap.
- **Masters' mutable RKE2 settings are drop-ins** in `/etc/rancher/rke2/config.yaml.d/` (`local.master_files` → output `master_config_files`, templates in `templates/master/`). They hold no secrets. cloud-init writes them on new masters. `scripts/sync-masters.sh` pushes them to running masters and restarts `rke2-server` one at a time, waiting for `/readyz`. It is manual, never run by apply.
- **Pod Security defaults to `baseline`** (only `kube-system` is exempt), and a Calico tier `metadata-guard` denies pods egress to `169.254.169.254`, except hcloud-csi. A workload that needs privilege or metadata access needs an explicit exception (`monitoring` and `velero` are `privileged`, for node-exporter and Velero's node agent).
- **The gateway's SSH host key is pinned.** `tls_private_key.gateway_host` is installed by cloud-init (`ssh_keys`), and `sync-gateway.sh` only connects with `StrictHostKeyChecking=yes` against the `gateway_known_hosts` output, never trust-on-first-use, because it pushes the WireGuard private key. Rotating that key means installing it on the running gateway first, over the existing trusted connection. Masters' host keys are read through the gateway (`scripts/pin-master-host-keys.sh` → git-ignored `master_known_hosts`), and `get-kubeconfig.sh`/`sync-masters.sh` connect only against that file; rerun the pin after replacing a master.
- **`protect = true` (default) enables Hetzner delete/rebuild protection** on the masters, the gateway primary IP and the network. `-replace`/destroy of those fails at apply time (not plan) until `protect = false` is applied first. The gateway and workers are intentionally unprotected.
- **No Hetzner firewalls on private-only servers.** Hetzner rejects them with `PrivateNetOnlyServer`. Isolation comes from having no public interface.
- **`terraform/cluster` also talks to Cloudflare.** The provider uses `cloudflare_provisioning_api_token`, which can mint tokens, so it never goes into the cluster. Terraform creates the R2 buckets (`rke2-etcd-snapshots`, `rke2-velero`, both `prevent_destroy`) and one narrow account token per consumer; R2 S3 credentials are the token's `id` and `sha256(value)`. `external-dns`/cert-manager use the Terraform-made `rke2-dns` token.
- **The worker floor is placeholder pods** (`capacity.tf`): one `pause` pod per location via a *required* zone anti-affinity, priority -10, Deployment strategy `Recreate` (a rolling update deadlocks on the anti-affinity). `min_workers` must not exceed `length(worker_locations)`. A topology spread is not enough: the scheduler and Karpenter only know zones that already have nodes. The NodePool also lists `worker_locations` as zone requirements.
- **Alerting leaves through the gateway NAT**, so the always-firing Watchdog goes to `deadmans_switch_url`. `telegram_bot_token` must be the whole `<id>:<secret>` (validated). Velero depends on kube-prometheus-stack for the ServiceMonitor/PrometheusRule CRDs.
- **kubectl OIDC via Pocket ID** (`pocket-id.tf`, public at `oidc_issuer_url`, an infra variable that cluster reads from remote state). The apiserver's `AuthenticationConfiguration` is a master drop-in, added only when `oidc_client_id` is set; its directory, not the file, is mounted into the static pod. Usernames are `oidc:<sub>` (email/username are user-editable), so RBAC binds groups only (`oidc:<group>`). The RKE2 admin kubeconfig stays as break-glass and is what `terraform/cluster` uses.
- **Masters carry the `CriticalAddonsOnly=true:NoExecute` taint.** Anything that must run there, like the Karpenter controller, needs that toleration and a control-plane nodeSelector.

## Conventions

- Make small, focused commits in conventional-commit style (`feat(infra):`, `feat(cluster):`, `fix(security):`, `docs:`), one concern per commit, validated before committing.
- Pin versions as variables: `rke2_version` (with `rke2_install_sha256`, the hash of that tag's `install.sh`), `ccm_chart_version`, `csi_chart_version`, `karpenter_chart_version`. Masters and workers must run the same RKE2 version.
- Terraform state, `kubeconfig`, `wg/`, and `*.tfvars` are git-ignored and contain secrets.
