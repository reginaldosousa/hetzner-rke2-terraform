# Documentação

Cluster Kubernetes RKE2 na Hetzner Cloud, provisionado com Terraform. Workers sob demanda via Karpenter, nós
sem IP público e um gateway WireGuard como único host exposto.

O [README da raiz](../README.md) traz o passo a passo de bootstrap. Esta pasta explica **como** as peças se
encaixam e **por que** cada uma foi escolhida.

| Documento | Conteúdo |
|---|---|
| [architecture.md](architecture.md) | Topologia, endereçamento, fluxos de tráfego e ordem de bootstrap |
| [stack.md](stack.md) | Cada componente da stack, o papel dele e o motivo da escolha |
| [operations.md](operations.md) | Runbooks: VPN, upgrades, proteção, state, destruição |
| [costs.md](costs.md) | Custo por recurso, cenários, serviços externos e risco de disponibilidade |
| [security.md](security.md) | Modelo de ameaças, segredos e superfícies de ataque |
| [adr/](adr/README.md) | Architecture Decision Records: as decisões, alternativas e consequências |

## Mapa rápido do repositório

```
terraform/infra/      root 1: só fala com a API da Hetzner (rede, gateway, masters)
  templates/          cloud-init de gateway, masters e workers
  templates/gateway/  arquivos mutáveis do gateway (wg0, nftables, haproxy)
terraform/cluster/    root 2: só fala com o Kubernetes, via VPN
  charts/nodepools/   HCloudNodeClass + NodePool do Karpenter (chart local)
  charts/cluster-issuers/  ClusterIssuers do cert-manager (chart local)
scripts/              get-kubeconfig, pin-master-host-keys, sync-gateway, sync-masters, backup-state
examples/whoami.yaml  smoke test de ingress + DNS + TLS
.github/workflows/    CI estático (fmt, validate, tflint, trivy, helm lint, shellcheck)
```
