# Architecture Decision Records

Cada ADR registra uma decisão: o contexto, o que foi decidido, as alternativas e as consequências. ADRs não
são editados depois de aceitos. Se uma decisão muda, um ADR novo a substitui (`Substituído por NNNN`).

Para criar um ADR, copie [`template.md`](template.md) para o próximo número livre.

| # | Decisão | Status |
|---|---|---|
| [0001](0001-hetzner-cloud.md) | Hetzner Cloud como provedor | Aceito |
| [0002](0002-rke2.md) | RKE2 como distribuição Kubernetes | Aceito |
| [0003](0003-private-network-wireguard-gateway.md) | Nós só na rede privada, gateway WireGuard como único host público | Aceito |
| [0004](0004-haproxy-control-plane-endpoint.md) | HAProxy no gateway como endpoint do control plane, em vez de LB pago | Aceito (substitui o LB privado) |
| [0005](0005-karpenter-workers.md) | Workers provisionados pelo Karpenter (provider Hetzner comunitário) | Aceito |
| [0006](0006-two-terraform-roots.md) | Dois roots Terraform: `infra` e `cluster` | Aceito |
| [0007](0007-state-cloudflare-r2.md) | State remoto no Cloudflare R2 com `use_lockfile` | Aceito |
| [0008](0008-secrets-out-of-user-data.md) | Tokens separados e segredos fora do user_data | Aceito |
| [0009](0009-gateway-config-sync.md) | Configuração do gateway sincronizada in-place, fail-closed, com host key fixada | Aceito |
| [0010](0010-arm64-cax.md) | arm64 (`cax`) em todos os nós | Aceito |
| [0011](0011-ingress-traefik-hetzner-lb.md) | Ingress com Traefik do RKE2 atrás de um Hetzner LB criado pelo CCM | Aceito |
| [0012](0012-dns-tls-cloudflare.md) | DNS e TLS: external-dns + cert-manager com DNS-01 no Cloudflare | Aceito |
| [0013](0013-delete-protection.md) | Proteção contra deleção/rebuild nos recursos críticos | Aceito |
| [0014](0014-local-helm-charts-for-crds.md) | Recursos que dependem de CRDs em charts Helm locais | Aceito |
| [0015](0015-static-only-ci.md) | CI apenas estático; applies locais pela VPN | Aceito |
| [0016](0016-ccm-csi-auto-deploy.md) | CCM e CSI via auto-deploy manifests do RKE2 | Aceito |
