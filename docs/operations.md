# Operações

Runbooks do dia a dia. Todos os comandos que tocam o cluster ou o gateway exigem a **VPN ativa** e o perfil AWS
`r2` configurado (state remoto).

## Antes e depois de todo apply

```bash
sudo wg-quick up wg/laptop.conf             # ou o app WireGuard
terraform -chdir=terraform/infra plan -out=tfplan
terraform -chdir=terraform/infra apply tfplan
scripts/backup-state.sh                     # R2 não tem versionamento
```

Validação estática antes de commitar:

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/infra validate
terraform -chdir=terraform/cluster validate
helm lint terraform/cluster/charts/nodepools
scripts/sync-gateway.sh --dry-run           # drift do gateway vs. Terraform
```

## VPN

### Adicionar um cliente
1. Em `terraform/infra/terraform.tfvars`, adicione `vpn_clients = { laptop = 10, ci = 11 }`. O número é o host
   em `10.200.0.0/24` e nunca muda.
2. `terraform apply`. O `terraform_data.gateway_sync` envia o novo `wg0.conf` e aplica com `wg syncconf`, sem
   rebuild e sem derrubar túneis.
3. Entregue a configuração ao cliente: `terraform output -json vpn_client_configs | jq -r .ci`.

### Remover / revogar
Remova a entrada e rode `apply`. O sync é **fail-closed**: se não conseguir enviar (VPN caída, configuração
inválida), o apply falha e o próximo tenta de novo. Um peer revogado nunca continua com acesso em silêncio.

### Drift do gateway
`scripts/sync-gateway.sh --dry-run` mostra o diff entre o gateway e o Terraform, com as chaves privadas
ocultadas.

## Upgrades

| O quê | Como |
|---|---|
| RKE2 | Altere `rke2_version`. Os masters ignoram mudanças de `user_data`, então atualize-os in-place (por exemplo, com system-upgrade-controller). Workers novos já sobem na versão nova, e os antigos são trocados por drift/consolidação. |
| CCM / CSI | Altere `ccm_chart_version`/`csi_chart_version`. Só masters novos recebem o manifest novo. Nos existentes, atualize a versão em `/var/lib/rancher/rke2/server/manifests/hcloud.yaml` em cada master (via SSH na VPN). O RKE2 reaplica o arquivo, e uma edição feita só no objeto `HelmChart` seria sobrescrita por ele. |
| Karpenter | Aplique os CRDs novos **antes** (o Helm não atualiza CRDs) e depois altere `karpenter_chart_version`. |
| external-dns / cert-manager | Altere a variável e rode `terraform apply` no root `cluster`. |

## Proteção contra deleção

Masters, IP primário do gateway e rede têm `delete_protection`/`rebuild_protection` (`protect = true`). O plan
**mostra** o destroy, mas o apply falha. Para substituir de propósito:

```bash
terraform apply -var protect=false          # in-place
terraform apply -replace=hcloud_server.master[2] -var protect=false
terraform apply                             # protect volta a true
```

Gateway e workers são descartáveis e não têm proteção.

## Rebuild do gateway

```bash
terraform -chdir=terraform/infra apply -replace=hcloud_server.gateway
```

O IP público é mantido (IP primário). O cloud-init reinstala os arquivos e a host key fixada, e o sync roda
porque o ID do servidor mudou. Enquanto ele sobe, os nós ficam sem egress e kubectl e joins ficam indisponíveis,
mas os nós já no cluster continuam falando com os masters.

## State

- Backup: `scripts/backup-state.sh` → `state-backups/<root>/` (git-ignored, 30 cópias por root).
- Restore: `terraform -chdir=terraform/<root> state push state-backups/<root>/<arquivo>.tfstate`.
- Lock preso: `terraform force-unlock <ID>`, só depois de confirmar que nenhum apply está rodando.

## Escala

- Teto de vCPU dos workers: `nodepool_cpu_limit` (padrão 32).
- Localizações dos workers: `worker_locations` (precisam estar na network zone da rede, `eu-central`).
- Masters `cax11` comportam bem até umas dezenas de workers. Acima de ~50, aumente `master_server_type`.

## Destruir tudo

```bash
kubectl -n kube-system delete svc rke2-traefik   # remove o LB criado pelo CCM (senão ele continua cobrando)
kubectl delete nodepool default                  # Karpenter remove os workers
terraform -chdir=terraform/cluster destroy
terraform -chdir=terraform/infra apply -var protect=false
terraform -chdir=terraform/infra destroy -var protect=false -var gateway_sync=false
```

Confira no console da Hetzner se sobrou algum servidor `role=worker` ou volume CSI.

## Troubleshooting rápido

| Sintoma | Causa provável |
|---|---|
| Nós `NotReady`/`uninitialized` logo após o bootstrap | Secret `kube-system/hcloud` ainda não existe: aplique `terraform/cluster` |
| Worker criado mas não entra | sem egress (gateway/NAT), ou `rke2_version` diferente dos masters; veja `/var/log/cloud-init-output.log` via SSH na VPN |
| NodeClaim travada | `kubectl get hcloudnodeclass default` precisa estar `READY=True`; capacidade esgotada na localização |
| NodeClaim não cria servidor e o log mostra tipo indisponível | `cax` esgotado nas localizações; ver [costs.md](costs.md#disponibilidade-e-risco-de-custo-2026-10-27) |
| Apply do `infra` falha no `gateway_sync` | VPN caída ou host key divergente; suba a VPN e rode de novo |
| App não vê o IP real | Traefik fora de nós com `externalTrafficPolicy: Local`, ou origem fora de `network_cidr` |
| Certificado não emite | `kubectl describe certificate,challenge -A`; confira o escopo do token Cloudflare e `external_dns_domains` |
