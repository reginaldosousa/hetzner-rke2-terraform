# hetzner-cloud

RKE2 Kubernetes cluster on Hetzner Cloud:

- 3 RKE2 server (control-plane) nodes managed by Terraform
- Worker nodes provisioned on demand by [Karpenter](https://karpenter.sh) using the
  community [Hetzner provider](https://github.com/paperclipinc/karpenter-provider-hetzner)
- A private network — no cluster node has a public IP
- A WireGuard gateway as the only public host (VPN entry + NAT for egress)

> Work in progress — see the git history for how the project is built step by step.
