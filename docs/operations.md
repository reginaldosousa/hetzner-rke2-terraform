# Operações

Runbooks do dia a dia. Todos os comandos que tocam o cluster ou o gateway exigem a **VPN ativa** e o perfil AWS
`r2` configurado (state remoto).

## Antes e depois de todo apply

```bash
sudo wg-quick up wg/laptop.conf             # ou o app WireGuard
terraform -chdir=terraform/infra plan -out=tfplan
terraform -chdir=terraform/infra apply tfplan
scripts/sync-masters.sh --dry-run           # se mudou algo em templates/master/: rode sem --dry-run
terraform -chdir=terraform/cluster plan -out=tfplan
terraform -chdir=terraform/cluster apply tfplan
scripts/backup-state.sh                     # R2 não tem versionamento; copia também para o bucket
```

Se um apply for interrompido (Ctrl-C, terminal fechado), o lock pode ficar no R2. Confirme que nenhum
`terraform` está rodando (`ps -ax | grep terraform`) antes de liberar com
`terraform -chdir=terraform/<root> force-unlock <ID do erro>`.

Validação estática antes de commitar:

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/infra validate
terraform -chdir=terraform/cluster validate
helm lint terraform/cluster/charts/nodepools
scripts/sync-gateway.sh --dry-run           # drift do gateway vs. Terraform
scripts/sync-masters.sh --dry-run           # drift da config do RKE2 nos masters
```

## VPN

Há duas VPNs para a mesma rede: a **tailnet (Headscale)**, de uso diário, com login no Pocket ID, e o
**WireGuard estático**, break-glass e caminho dos applies ([ADR 0025](adr/0025-headscale-oidc-vpn.md)).
As duas anunciam `10.0.0.0/16`: ligue uma de cada vez.

### Tailnet (Headscale)
```bash
tailscale up --login-server https://vpn.devcomm.com.br --accept-routes   # abre o Pocket ID no navegador
tailscale status                                                          # "gateway" deve aparecer
```

- **Dar acesso:** o usuário em `users` do `terraform/identity` com o grupo `vpn`, e `apply` do `identity`.
- **Revogar:** tire o grupo `vpn` (bloqueia novos logins) e corte a sessão ativa no gateway:
  `headscale nodes list` e `headscale nodes expire --identifier <id>`.
- **Policy** (`templates/gateway/headscale-policy.hujson.tftpl`): o `sync-gateway.sh` a valida no Headscale em
  execução e recarrega com SIGHUP. Config, secret ou versões mudadas rodam o instalador, que reinicia o serviço.
- **Rebuild do gateway:** o banco do Headscale se perde; o `tailnet-join.service` registra o gateway de novo e os
  usuários refazem o `tailscale up`.
- **Primeira vez** (ordem): `headscale_hostname` no `infra` e `apply`; `apply` do `cluster` (registro DNS);
  `apply` do `identity` (client OIDC); `headscale_oidc_client_id`/`_secret` no `infra` a partir de
  `terraform -chdir=terraform/identity output` e `apply` do `infra`, com o WireGuard ligado.

### WireGuard: adicionar um cliente
1. Em `terraform/infra/terraform.tfvars`, adicione `vpn_clients = { laptop = 10, ci = 11 }`. O número é o host
   em `10.200.0.0/24` e nunca muda.
2. `terraform apply`. O `terraform_data.gateway_sync` envia o novo `wg0.conf` e aplica com `wg syncconf`, sem
   rebuild e sem derrubar túneis.
3. Entregue a configuração ao cliente: `terraform output -json vpn_client_configs | jq -r .ci`.

### WireGuard: remover / revogar
Remova a entrada e rode `apply`. O sync é **fail-closed**: se não conseguir enviar (VPN caída, configuração
inválida), o apply falha e o próximo tenta de novo. Um peer revogado nunca continua com acesso em silêncio.

### Configuração do RKE2 nos masters
Os masters ignoram `user_data`. Pod Security e snapshots do etcd vivem em arquivos de
`/etc/rancher/rke2/config.yaml.d/` (output `master_config_files`). Depois de um `apply` do `infra` que mude esses
arquivos:

```bash
scripts/sync-masters.sh --dry-run   # diff por master
scripts/sync-masters.sh             # envia e reinicia um master por vez, esperando /readyz
```

Se um master não voltar, o script para antes do próximo (o etcd segue com 2 de 3). Veja
`journalctl -u rke2-server` nele, corrija e rode de novo.

### Login OIDC no kubectl (Pocket ID)
Primeira vez ([ADR 0023](adr/0023-oidc-pocket-id.md)):

1. `oidc_issuer_url` no `terraform.tfvars` do `infra`. No do `cluster`,
   `pocket_id_allowed_cidrs = ["<seu IP público>/32"]`, porque até existir um admin qualquer um pode criá-lo em
   `/setup`. Rode `apply` do `infra` e depois do `cluster`.
2. Abra `https://auth.devcomm.com.br/setup` e crie o admin com uma passkey. Depois troque para
   `pocket_id_allowed_cidrs = []` e rode `apply` do `cluster` para deixar o Pocket ID público.
3. No Pocket ID, crie uma API key (*Settings → Admin → API Keys*, com validade) e coloque em
   `terraform/identity/terraform.tfvars` (`pocket_id_api_token`), com os usuários em `users`. O `apply` do
   `identity` cria o grupo `k8s-admins`, o client `kubectl` e as associações ([ADR 0024](adr/0024-identity-root-pocketid-provider.md)).
4. Coloque `terraform -chdir=terraform/identity output -raw kubectl_client_id` em `oidc_client_id`, rode `apply`
   do `infra` e `scripts/sync-masters.sh`.
5. No laptop (`brew install kubelogin` ou `kubectl krew install oidc-login`):

```bash
kubectl config set-credentials oidc \
  --exec-api-version=client.authentication.k8s.io/v1 --exec-interactive-mode=IfAvailable \
  --exec-command=kubectl --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://auth.devcomm.com.br \
  --exec-arg=--oidc-client-id=<client id> --exec-arg=--oidc-extra-scope=groups
kubectl --user=oidc auth whoami   # oidc:<sub>, grupos oidc:k8s-admins
```

Acesso novo = usuário em `users` com o grupo, `apply` do `identity` e um link de acesso único (UI) para ele
cadastrar a passkey. Para revogar, tire o grupo ou ponha `disabled = true` no `users` e rode o `apply` (desativar
só pela UI é desfeito no próximo `apply`); tokens já emitidos valem
até expirar. O `kubeconfig` admin do RKE2 continua sendo o break-glass e o que o `terraform/cluster` usa.

### Drift do gateway
`scripts/sync-gateway.sh --dry-run` mostra o diff entre o gateway e o Terraform, com as chaves privadas
ocultadas.

## Upgrades

| O quê | Como |
|---|---|
| RKE2 | Altere `rke2_version` e `rke2_install_sha256` (comando na descrição da variável). Os masters ignoram mudanças de `user_data`, então atualize-os in-place (por exemplo, com system-upgrade-controller). Workers novos já sobem na versão nova, e os antigos são trocados por drift/consolidação. |
| CCM / CSI | Altere `ccm_chart_version`/`csi_chart_version`. Só masters novos recebem o manifest novo. Nos existentes, atualize a versão em `/var/lib/rancher/rke2/server/manifests/hcloud.yaml` em cada master (via SSH na VPN). O RKE2 reaplica o arquivo, e uma edição feita só no objeto `HelmChart` seria sobrescrita por ele. |
| Karpenter | Aplique os CRDs novos **antes** (o Helm não atualiza CRDs) e depois altere `karpenter_chart_version`. |
| external-dns / cert-manager / kured | Altere a variável e rode `terraform apply` no root `cluster`. |
| SO dos nós | Automático: unattended-upgrades instala, o kured reinicia um nó por vez entre 01:00 e 05:00, e os workers são trocados a cada 30 dias. Pausar: `kubectl -n kube-system annotate ds kured weave.works/kured-node-lock='{"nodeID":"manual"}'`; retomar removendo a anotação. |

## Proteção contra deleção

Masters, IP primário do gateway e rede têm `delete_protection`/`rebuild_protection` (`protect = true`). O plan
**mostra** o destroy, mas o apply falha. Para substituir de propósito:

```bash
terraform apply -var protect=false          # in-place
terraform apply -replace=hcloud_server.master[2] -var protect=false
terraform apply                             # protect volta a true
```

Gateway e workers são descartáveis e não têm proteção.

## Substituir um master

O Karpenter não escolhe IP: um worker recebe o primeiro IP livre da sub-rede, que pode ser o de um master
enquanto ele está sendo recriado (`.11` a `.13`). Durante a troca, pare o Karpenter para que nenhum worker nasça
nesse intervalo:

```bash
kubectl -n kube-system scale deploy karpenter-karpenter-provider-hetzner --replicas=0
# terraform apply -replace='hcloud_server.master[N]'  (protect = false antes, ver acima)
kubectl -n kube-system scale deploy karpenter-karpenter-provider-hetzner --replicas=1
```

Depois, atualize as host keys fixadas: `scripts/pin-master-host-keys.sh` (o master novo tem chave nova, e os
scripts recusam a conexão até isso). Se o IP já estiver ocupado, o apply falha (não sobe com outro IP); drene e apague o worker que o pegou.

## Rebuild do gateway

```bash
terraform -chdir=terraform/infra apply -replace=hcloud_server.gateway
```

O IP público é mantido (IP primário). O cloud-init reinstala os arquivos e a host key fixada, e o sync roda
porque o ID do servidor mudou. Enquanto ele sobe, os nós ficam sem egress e kubectl e joins ficam indisponíveis,
mas os nós já no cluster continuam falando com os masters.

## State

- Backup: `scripts/backup-state.sh` → `state-backups/<root>/` (git-ignored) e `s3://rke2-tfstate/backups/<root>/`, 30 cópias por root em cada. Restore: `aws --profile r2 s3 cp s3://rke2-tfstate/backups/<root>/<ts>.tfstate .` e `terraform state push`.
- Restore: `terraform -chdir=terraform/<root> state push state-backups/<root>/<arquivo>.tfstate`.
- Lock preso: `terraform force-unlock <ID>`, só depois de confirmar que nenhum apply está rodando.

## etcd

Snapshots a cada 6 h, locais e no R2 (`rke2-etcd-snapshots/<cluster_name>/`), 7 dias de retenção
([ADR 0019](adr/0019-etcd-snapshots-r2.md)).

```bash
kubectl get etcdsnapshotfiles                      # lista locais e S3 (coluna LOCATION)
ssh root@10.0.1.11 rke2 etcd-snapshot save          # snapshot sob demanda (usa o Secret)
```

### Restore (perda do etcd)
O Secret não vale para restore: passe as opções S3 na linha de comando. Precisa do token de server original,
que está no state do `infra` (`terraform -chdir=terraform/infra state show random_password.rke2_token`), mas os
masters já o têm no `config.yaml`.

1. Pare o RKE2 nos três masters: `systemctl stop rke2-server`.
2. No master-1:
   ```bash
   rke2 server --cluster-reset \
     --etcd-s3 --etcd-s3-endpoint=<endpoint> --etcd-s3-bucket=rke2-etcd-snapshots \
     --etcd-s3-folder=<cluster_name> --etcd-s3-region=auto --etcd-s3-bucket-lookup-type=path \
     --etcd-s3-access-key=<...> --etcd-s3-secret-key=<...> \
     --cluster-reset-restore-path=<nome do snapshot>
   systemctl start rke2-server
   ```
3. Nos masters 2 e 3: `rm -rf /var/lib/rancher/rke2/server/db` e `systemctl start rke2-server`.

## Escala

- Teto de vCPU dos workers: `nodepool_cpu_limit` (padrão 32).
- Mínimo de workers: `min_workers` (padrão 2, um por localização), mantido por pods placeholder
  ([ADR 0020](adr/0020-worker-floor-and-node-reboots.md)).
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

## Backups do Velero

Diário às 23:00, 7 dias, no R2 `rke2-velero/<cluster_name>/` ([ADR 0022](adr/0022-velero-r2.md)). Use o CLI
`velero` (ou `kubectl -n velero get backups`):

```bash
velero backup get                                         # lista
velero backup create manual-$(date +%s) --from-schedule velero-daily
velero restore create --from-backup <backup> --include-namespaces <ns>
```

## Monitoramento

Alertas vão para o Telegram (`telegram_chat_id`), e o `Watchdog` para o dead man's switch
([ADR 0021](adr/0021-monitoring-telegram.md)).

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80        # http://localhost:3000
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093      # silenciar alertas
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090        # Status > Targets
```

## Troubleshooting rápido

| Sintoma | Causa provável |
|---|---|
| Nós `NotReady`/`uninitialized` logo após o bootstrap | Secret `kube-system/hcloud` ainda não existe: aplique `terraform/cluster` |
| Worker criado mas não entra | sem egress (gateway/NAT), ou `rke2_version` diferente dos masters; veja `/var/log/cloud-init-output.log` via SSH na VPN |
| NodeClaim travada | `kubectl get hcloudnodeclass default` precisa estar `READY=True`; capacidade esgotada na localização |
| NodeClaim não cria servidor e o log mostra tipo indisponível | `cax` esgotado nas localizações; ver [costs.md](costs.md#disponibilidade-e-risco-de-custo-2026-10-27) |
| Apply do `infra` falha no `gateway_sync` | VPN caída ou host key divergente; suba a VPN e rode de novo |
| App não vê o IP real | Traefik fora de nós com `externalTrafficPolicy: Local`, ou origem fora de `network_cidr` |
| Worker sobe mas o `rke2-agent` não existe | `sha256sum -c` do instalador falhou: `rke2_install_sha256` não corresponde ao `install.sh` da tag de `rke2_version` |
| Placeholder `Pending` em `capacity` | sem capacidade `cax` numa localização, ou `min_workers` maior que o número de `worker_locations` |
| Scripts recusam SSH num master (`Host key verification failed`) | master recriado: rode `scripts/pin-master-host-keys.sh` |
| kured não reinicia um nó com patch pendente | fora da janela (01:00–05:00), outro nó com o lock, ou drain bloqueado por PDB (desiste após 30 min): `kubectl -n kube-system logs ds/kured` |
| `VeleroNoRecentBackup` / BSL `Unavailable` | `kubectl -n velero get backupstoragelocation`; o token R2 do Velero foi revogado ou o bucket mudou |
| Alertmanager loga `telegram: Not Found (404)` | token do bot incompleto (falta `<id>:`) ou chat ID errado; o bot só conhece um chat depois de receber uma mensagem nele |
| Certificado não emite | `kubectl describe certificate,challenge -A`; confira o escopo do token Cloudflare e `external_dns_domains` |
