# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform for an RKE2 Kubernetes cluster on Hetzner Cloud. It has 3 Terraform-managed masters, workers provisioned by Karpenter (community provider `stubbi/karpenter-provider-hetzner`), a private network where no cluster node has a public IP, and a WireGuard gateway as the only public host. README.md has the bootstrap steps and the architecture diagram.

## Commands

There are no tests. Validation is static, and each change gets a render check:

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/infra validate     # needs `terraform init -backend=false` once
terraform -chdir=terraform/cluster validate
helm lint terraform/cluster/charts/nodepools
helm template t terraform/cluster/charts/nodepools --set networkID=12345678 --set sshKeyID=98765432
```

Render a cloud-init template to check the output. Run this from `terraform/infra`, passing the template's vars, and use `printf`, not zsh `echo`, which mangles `\n`:

```bash
printf '%s\n' 'templatefile("templates/worker-userdata.yaml.tftpl", {lb_ip="10.0.1.10", token="T", rke2_version="v", private_network_script="echo"})' \
  | terraform console -var hcloud_token=x -var ssh_public_key=x
```

## Architecture (cross-file facts)

- **Two Terraform roots, applied in order.**
  - `terraform/infra` talks only to the Hetzner API.
  - `terraform/cluster` talks to Kubernetes through `../../kubeconfig`, so it only works with the WireGuard tunnel up. It reads infra's outputs through `terraform_remote_state` from the *local* state file `../infra/terraform.tfstate`. Changing infra's backend or outputs breaks `cluster`.
- **Fixed private IPs** are computed with `cidrhost` in `network.tf` locals:
  - gateway `.2`
  - load balancer `.10`
  - masters `.11` to `.13`

  The router that private-only servers use as their default gateway is `cidrhost(network_cidr, 1)`. The hcloud network route `0.0.0.0/0 → gateway` then forwards their traffic to the NAT gateway.
- **`templates/private-network.sh.tftpl` is shared** by the master and worker cloud-init. It must run before anything downloads, because private-only servers have no default route until it does. Its result is embedded with `indent(6, …)`.
- **Bootstrap dependency.** The masters' cloud-init deploys the CCM and CSI HelmCharts, but the `kube-system/hcloud` Secret (API token and network ID) is created by `terraform/cluster`. Nodes stay `uninitialized` until that root is applied. Keep the API token out of user_data, because pods can read user_data from the metadata service.
- **Tokens.** Masters have both `token` and `agent-token`. Workers get only the agent token, through the `worker_user_data` output → Secret `karpenter-worker-bootstrap` → `HCloudNodeClass.userDataSecretRef`.
- **Karpenter contracts the worker userData must keep:**
  - the `karpenter.sh/unregistered=:NoExecute` taint
  - `cloud-provider-name: external`, so the CCM sets the `hcloud://` providerID
  - `kube-reserved` matching `spec.kubelet` in the NodeClass

  In the CCM, `HCLOUD_INSTANCES_ZONE_LABEL_ENABLED=false` leaves the zone label to Karpenter. Keep NodePools pinned to `capacity-type: on-demand`, because Hetzner has no spot capacity.
- **NodeClass and NodePool live in a local Helm chart** (`terraform/cluster/charts/nodepools`), because `kubernetes_manifest` can't plan before the Karpenter CRDs exist. Numeric IDs in its templates need `| int64`, or Helm renders them as `1.2e+07`.
- **Masters ignore `user_data` and `image` changes**, so editing their template only affects newly built masters. The gateway has no such guard, so changing `vpn_clients` or its template **recreates the gateway**, along with its public IP.
- **No Hetzner firewalls on private-only servers.** Hetzner rejects them with `PrivateNetOnlyServer`. Isolation comes from having no public interface.
- **Masters carry the `CriticalAddonsOnly=true:NoExecute` taint.** Anything that must run there, like the Karpenter controller, needs that toleration and a control-plane nodeSelector.

## Conventions

- Make small, focused commits in conventional-commit style (`feat(infra):`, `feat(cluster):`, `fix(security):`, `docs:`), one concern per commit, validated before committing.
- Pin versions as variables: `rke2_version`, `ccm_chart_version`, `csi_chart_version`, `karpenter_chart_version`. Masters and workers must run the same RKE2 version.
- Terraform state, `kubeconfig`, `wg/`, and `*.tfvars` are git-ignored and contain secrets.
