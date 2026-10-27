# Custos

Preços consultados na API da Hetzner (`GET /v1/pricing` e `GET /v1/server_types`) em **2026-10-27**, para
`nbg1`/`fsn1`. Esta conta é cobrada em **USD, sem IVA**. Contas em EUR ou com IVA veem outros valores. A
Hetzner cobra por hora até o teto mensal, e os preços mudam: revise esta página antes de decisões de custo.

## Custo fixo (sempre ligado)

| Recurso | Terraform / origem | Qtde | Unitário/mês | Total/mês |
|---|---|---|---|---|
| Gateway `cax11` (2 vCPU arm, 4 GB, 40 GB) | `hcloud_server.gateway` | 1 | US$ 6,99 | US$ 6,99 |
| Masters `cax11` | `hcloud_server.master` | 3 | US$ 6,99 | US$ 20,97 |
| IPv4 primário do gateway | `hcloud_primary_ip.gateway` | 1 | US$ 0,60 | US$ 0,60 |
| LB de ingress `lb11` (IPs inclusos) | criado pelo CCM ([ADR 0011](adr/0011-ingress-traefik-hetzner-lb.md)) | 1 | US$ 7,89 | US$ 7,89 |
| Piso de workers `cax11` (`min_workers = 2`) | pods placeholder ([ADR 0020](adr/0020-worker-floor-and-node-reboots.md)) | 2 | US$ 6,99 | US$ 13,98 |
| Volumes do Prometheus (20 GB) e do Alertmanager (10 GB) | `monitoring.tf` ([ADR 0021](adr/0021-monitoring-telegram.md)) | 30 GB | US$ 0,0767/GB | US$ 2,30 |
| Volume do Pocket ID (SQLite) | `pocket-id.tf` ([ADR 0023](adr/0023-oidc-pocket-id.md)) | 10 GB | US$ 0,0767/GB | US$ 0,77 |
| **Subtotal fixo** | | | | **US$ 53,50** |

Sem custo: rede privada, subnet, rotas, firewall, placement group, chave SSH e IPv6 primário.

## Custo variável

| Recurso | Preço | Observação |
|---|---|---|
| Workers Karpenter `cax11` | US$ 6,99/mês (US$ 0,0112/h) | por worker, cobrado por hora enquanto existir |
| `cax21` / `cax31` / `cax41` | US$ 12,49 / 24,99 / 48,49 | o Karpenter pode escolher conforme os pedidos dos pods |
| Volumes CSI (`hcloud-volumes`) | US$ 0,0767/GB/mês | mínimo de 10 GB (≈ US$ 0,77); além dos 40 GB fixos (monitoramento e Pocket ID), nenhum em uso hoje |
| Tráfego | 20 TB inclusos por servidor e pelo LB; excedente US$ 1,20/TB | tráfego na rede privada não é cobrado |
| Backups Hetzner | +20% do servidor | desligados |

## Cenários

| Cenário | Composição | Total/mês |
|---|---|---|
| Mínimo / **hoje (2026-10-27)** | fixo, com os 2 workers do piso (`default-dfl4l` em fsn1, `default-lpclv` em nbg1) | **US$ 53,50** |
| Com `min_workers = 1` | fixo − 1 worker; o ingress volta a depender de um nó só | US$ 46,51 |
| Masters `cax21` (decisão adiada) | fixo + 3 × US$ 5,50 | US$ 70,00 |
| Teto do NodePool, mais barato | fixo − piso + 32 vCPU como 2× `cax41` | US$ 136,50 |
| Teto do NodePool, mais caro | fixo − piso + 32 vCPU como 16× `cax11` | US$ 151,36 |

O teto vem de `nodepool_cpu_limit = 32`. Aumentar esse limite aumenta o gasto máximo possível. A consolidação
(`WhenEmptyOrUnderutilized`, 5 min) remove workers ociosos acima do piso, então o custo real fica perto do mínimo
enquanto não há carga.

## Serviços externos

| Serviço | Uso | Custo |
|---|---|---|
| Cloudflare R2 | state e backups dele, snapshots do etcd (28 por master), backups do Velero (7 dias) e réplica do banco do Headscale | US$ 0 dentro do free tier (10 GB, 1M operações classe A, 10M classe B, sem egress); acima de 10 GB, US$ 0,015/GB/mês |
| Telegram | alertas do Alertmanager | gratuito |
| healthchecks.io | dead man's switch do Watchdog | US$ 0 no plano Hobbyist |
| Cloudflare DNS | zonas gerenciadas pelo external-dns | US$ 0 no plano Free |
| Let's Encrypt | certificados via cert-manager | gratuito |
| GitHub Actions | CI estático em repo privado | dentro dos minutos inclusos do plano (o job leva poucos minutos) |

## Decisões que reduziram custo

| Decisão | Economia/mês |
|---|---|
| HAProxy no gateway em vez de LB privado `lb11` ([ADR 0004](adr/0004-haproxy-control-plane-endpoint.md)) | US$ 7,89 |
| Nós sem IP público ([ADR 0003](adr/0003-private-network-wireguard-gateway.md)) | US$ 0,60 por master e por worker (US$ 1,80 + 0,60 × workers) |
| NAT, VPN e endpoint do control plane no mesmo gateway | um servidor em vez de dois ou três |
| arm64 `cax11` ([ADR 0010](adr/0010-arm64-cax.md)) | tipo 2 vCPU/4 GB mais barato que existia à venda |
| Karpenter com consolidação ([ADR 0005](adr/0005-karpenter-workers.md)) | sem workers ociosos pagos |

## Disponibilidade e risco de custo (2026-10-27)

A disponibilidade de `cax` oscila. Na manhã de 2026-10-27 a API não mostrava **nenhum** `cax` à venda em `nbg1`,
`fsn1` ou `hel1`, e os tipos à venda eram `cpx02/12/22/32/42/52/62` e `ccx13–63`. À tarde, `cax11` voltou a
aparecer em `nbg1` e `fsn1`, e o Karpenter criou workers nas duas localizações.

Enquanto o `cax` estiver esgotado:

- **Workers:** o NodePool aceita somente `arm64` + família `cax`, então o Karpenter **não consegue criar
  workers novos** enquanto isso durar. Pods que precisem de capacidade nova ficam `Pending`. O worker que já
  existe continua funcionando.
- **Substituir master ou gateway** (rebuild, perda do servidor) exigiria trocar `*_server_type`. O tipo mais
  barato disponível que atende ao mínimo de 2 vCPU/4 GB do RKE2 é o `cpx22` (x86, US$ 22,99), mais de 3× o
  `cax11`. Isso também misturaria arquiteturas.

| Tipo disponível | Arch | vCPU / RAM | US$/mês |
|---|---|---|---|
| `cpx02` | x86 | 1 / 1 GB | 7,49 |
| `cpx12` | x86 | 1 / 2 GB | 13,49 |
| `cpx22` | x86 | 2 / 4 GB | 22,99 |
| `ccx13` | x86 dedicado | 2 / 8 GB | 50,49 |

Opções, se for preciso capacidade antes de o `cax` voltar: liberar `amd64` + família `cpx` no NodePool
(`architectures`/`serverFamilies` em `charts/nodepools/values.yaml`), aceitando custo maior e imagens
multi-arch, ou aguardar a reposição. Para consultar a disponibilidade:

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/server_types \
  | jq -r '.server_types[] | .name as $n | .locations[] | select(.available) | "\(.name) \($n)"'
```
