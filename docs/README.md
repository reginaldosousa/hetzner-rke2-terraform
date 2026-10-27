# Documentação

Cluster Kubernetes RKE2 na Hetzner Cloud, provisionado com Terraform. Workers sob demanda via Karpenter, nós
sem IP público e um gateway como único host exposto: VPN Headscale com login no Pocket ID (WireGuard estático
como break-glass) e NAT.

O [README da raiz](../README.md) traz o passo a passo de bootstrap. Esta pasta explica **como** as peças se
encaixam e **por que** cada uma foi escolhida.

| Documento | Conteúdo |
|---|---|
| [architecture.md](architecture.md) | Topologia, endereçamento, fluxos de tráfego e ordem de bootstrap |
| [stack.md](stack.md) | Cada componente da stack, o papel dele e o motivo da escolha |
| [operations.md](operations.md) | Runbooks: VPN, config dos masters, upgrades, proteção, state, etcd, Velero, monitoramento, destruição |
| [costs.md](costs.md) | Custo por recurso, cenários, serviços externos e risco de disponibilidade |
| [security.md](security.md) | Modelo de ameaças, segredos e superfícies de ataque |
| [adr/](adr/README.md) | Architecture Decision Records: as decisões, alternativas e consequências |

## Mapa rápido do repositório

```
terraform/infra/      root 1: só fala com a API da Hetzner (rede, gateway, masters)
  templates/          cloud-init de gateway, masters e workers
  templates/gateway/  arquivos mutáveis do gateway (wg0, nftables, haproxy, Headscale)
  templates/master/   drop-ins do RKE2 nos masters (Pod Security, etcd-s3, métricas, OIDC)
terraform/cluster/    root 2: só fala com o Kubernetes, via VPN
  charts/nodepools/   HCloudNodeClass + NodePool do Karpenter (chart local)
  charts/cluster-issuers/  ClusterIssuers do cert-manager (chart local)
  *.tf                Cloudflare (R2, tokens, DNS do Headscale), Pocket ID, RBAC OIDC, monitoramento,
                      Velero, kured, placeholders, metadata-guard
terraform/identity/   root 3: API do Pocket ID (grupos, clients OIDC, usuários)
scripts/              get-kubeconfig, pin-master-host-keys, sync-gateway, sync-masters, backup-state
examples/whoami.yaml  smoke test de ingress + DNS + TLS
.github/workflows/    CI estático (fmt, validate, tflint, trivy, helm lint, shellcheck)
```
