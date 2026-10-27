# 0005. Workers provisionados pelo Karpenter (provider Hetzner comunitário)

- **Status:** Aceito
- **Commits:** `4d7bcec`, `9f532f2`, `216931d`, `e0f55a6`

## Contexto

Gerenciar workers como `hcloud_server` com `count` no Terraform significa capacidade fixa (paga mesmo ociosa) e
escala manual. Queremos que o cluster crie nós quando há pods pendentes e remova nós ociosos.

## Decisão

Usamos o Karpenter com o provider comunitário
[`stubbi/karpenter-provider-hetzner`](https://github.com/stubbi/karpenter-provider-hetzner) (chart
`karpenter-provider-hetzner`, versão fixada em `karpenter_chart_version`).

- **HCloudNodeClass `default`:** Ubuntu 24.04, sem IP público, rede privada, placement group `spread`, userData
  vindo do Secret `karpenter-worker-bootstrap` e `kubeReserved` igual ao do userData.
- **NodePool `default`:** `capacity-type: on-demand`, arch `arm64`, família `cax`, localizações `nbg1`/`fsn1`,
  limite de 32 vCPU, `consolidationPolicy: WhenEmptyOrUnderutilized` após 1 min.
- O controller roda **nos masters** (nodeSelector de control plane + tolerations), porque não existem workers
  antes dele.

## Alternativas consideradas

- **Cluster Autoscaler com o provider hcloud:** maduro e oficial, mas trabalha com grupos de nós de tipo fixo,
  sem escolher o tipo pelo pedido dos pods e com consolidação mais fraca.
- **Workers estáticos no Terraform:** simples e previsíveis, mas sem elasticidade e com custo ocioso.
- **Escrever um provider próprio:** custo de manutenção alto demais.

## Consequências

- Os workers são gado: não estão no Terraform, não têm proteção e são trocados por drift/consolidação.
- Contratos a manter (ver [architecture.md](../architecture.md#contratos-entre-arquivos)): taint
  `karpenter.sh/unregistered`, `cloud-provider-name: external`, `kube-reserved` igual ao da NodeClass e
  `capacity-type: on-demand` (sem esse pin a consolidação quebra, porque a Hetzner não tem spot).
- O provider é **comunitário** e recebe o token da Hetzner com poder total sobre o projeto. A versão é fixada e
  upgrades exigem revisão. Os CRDs precisam ser aplicados antes de um upgrade de chart.
- Duas localizações dão fallback quando uma esgota a capacidade de `cax`.

## Atualizações
- **2026-10-27:** A consolidação passou para 5 min, com budget de um nó por vez e `expireAfter: 720h` explícito. Um
  piso de `min_workers` (2) é mantido por pods placeholder, um por localização, e o NodePool declara as
  localizações como zonas ([0020](0020-worker-floor-and-node-reboots.md)).
