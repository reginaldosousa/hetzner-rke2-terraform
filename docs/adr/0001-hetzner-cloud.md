# 0001. Hetzner Cloud como provedor

- **Status:** Aceito
- **Commits:** `200449d`

## Contexto

O objetivo é um cluster Kubernetes com control plane HA, autoscaling de workers, ingress público com TLS e
custo mensal baixo. Nos hyperscalers, só o control plane gerenciado e o NAT gateway já custam mais do que o
cluster inteiro aqui.

## Decisão

Usamos a Hetzner Cloud, com o provider Terraform oficial `hetznercloud/hcloud`, para servidores, rede privada,
IP primário, firewall, placement group, load balancer e volumes.

## Alternativas consideradas

- **EKS/GKE/AKS:** control plane, NAT e LB gerenciados, mas a um custo várias vezes maior.
- **DigitalOcean/Linode com Kubernetes gerenciado:** mais simples, mas sem controle sobre o control plane e com
  máquinas mais caras por vCPU/GB.
- **Hetzner Robot (dedicados):** mais barato por recurso, mas sem API de provisionamento rápido, o que inviabiliza
  o Karpenter.

## Consequências

- Custo muito baixo: três masters, gateway e LB de ingress custam US$ 36,45/mês fixos, ou US$ 43,44 com um worker ([custos](../costs.md)).
- Existe ecossistema para Kubernetes: hcloud CCM, hcloud CSI e um provider Karpenter comunitário.
- Limitações que moldam outras decisões: não há NAT gateway gerenciado ([0003](0003-private-network-wireguard-gateway.md)),
  não há firewall para servidores só privados, não há spot e a disponibilidade de tipos varia por localização
  ([0010](0010-arm64-cax.md)).
- Todos os nós precisam estar na mesma network zone (`eu-central`). As variáveis validam isso.
