# Segurança

## Superfície exposta

| Exposto | Protegido por |
|---|---|
| Gateway `udp/51820` | WireGuard: sem chave válida não há resposta |
| LB de ingress `80/443` | Traefik; só serve o que existe como Ingress. HTTP vira 308 para HTTPS |
| Tudo o mais | Nada tem IP público. Da VPN só SSH e API do Kubernetes; etcd e kubelet só pela rede privada |

Como a Hetzner não permite firewall em servidores só com rede privada, o isolamento dos masters e workers vem da
ausência de interface pública ([ADR 0003](adr/0003-private-network-wireguard-gateway.md)).

## Segredos e onde vivem

| Segredo | Onde | Quem lê |
|---|---|---|
| Token da API Hetzner | state do `infra` → Secret `kube-system/hcloud` | CCM, CSI, Karpenter. **Nunca** em user_data |
| RKE2 server `token` | user_data dos masters | masters. Pods bloqueados no metadata ([ADR 0017](adr/0017-block-instance-metadata-for-pods.md)) |
| RKE2 `agent-token` | user_data dos workers (Secret `karpenter-worker-bootstrap`) | workers. Só permite entrar como agent |
| Chaves WireGuard | state do `infra`, `/etc/wireguard/wg0.conf`, `wg/` local | gateway e clientes |
| Host key SSH do gateway | state do `infra` (`tls_private_key.gateway_host`) | gateway; output `gateway_known_hosts` para fixar |
| Token Cloudflare (DNS) | token criado pelo `cluster` (`dns-token.tf`) → Secrets do external-dns e do cert-manager | escopo Zone Read + DNS Write só nas zonas de `external_dns_domains` |
| Credenciais R2 (state) | perfil AWS `r2` local | operador; **fora do CI** |
| Credenciais R2 (snapshots do etcd) | token criado pelo `cluster` → Secret `kube-system/rke2-etcd-snapshot-s3` | RKE2 nos masters; escopo só no bucket `rke2-etcd-snapshots` |
| Token do bot do Telegram / URL do dead man's switch | state do `cluster` → Secret `monitoring/alertmanager-receivers` | Alertmanager |
| Credenciais R2 (Velero) | token criado pelo `cluster` → Secret `velero/velero-r2` | Velero; escopo só no bucket `rke2-velero` |
| Token Cloudflare de provisionamento | `terraform.tfvars` do `cluster` (provider) | operador; cria buckets R2 e tokens, **nunca** vai para o cluster |

O **state do Terraform contém todos esses segredos** e fica no R2, criptografado em repouso pela Cloudflare mas
sem criptografia do lado do cliente. Quem tem o token do R2 lê tudo, por isso ele tem escopo restrito ao bucket.
`kubeconfig`, `wg/`, `*.tfvars` e `state-backups/` são ignorados pelo git.

## Decisões de defesa

- **Separação de tokens** ([ADR 0008](adr/0008-secrets-out-of-user-data.md)): o user_data é legível pelo
  metadata service (`169.254.169.254`), inclusive por pods. Por isso workers recebem só o agent token, e o token
  da Hetzner não aparece em user_data nenhum.
- **Pod Security `baseline` por padrão** ([ADR 0018](adr/0018-pod-security-baseline.md)): fora do
  `kube-system`, nada de pods privilegiados, `hostPath` ou `hostNetwork`. `restricted` só gera aviso.
- **Metadata service bloqueado para pods** ([ADR 0017](adr/0017-block-instance-metadata-for-pods.md)).
- **Revogação de VPN fail-closed** ([ADR 0009](adr/0009-gateway-config-sync.md)): remover um peer sem conseguir
  aplicar no gateway faz o `apply` falhar.
- **Host key fixada**: `sync-gateway.sh` envia a chave privada do WireGuard e só conecta com
  `StrictHostKeyChecking=yes` contra a chave conhecida, nunca trust-on-first-use. Numa LAN estranha que também
  use `10.0.x.x`, ele recusa em vez de entregar a chave. As host keys dos masters são lidas **pelo gateway**
  (`pin-master-host-keys.sh`, `ssh-keyscan` na rede privada) para `master_known_hosts`, e `get-kubeconfig.sh` e
  `sync-masters.sh` também usam `StrictHostKeyChecking=yes`. Depois de trocar um master, rode o pin de novo.
- **nftables no gateway** além do firewall da Hetzner: a chain `input` (policy drop) só aceita WireGuard, SSH
  vindo do túnel e HAProxy (`6443`/`9345`) vindo da rede privada ou da VPN. A chain `forward` deixa clientes VPN
  abrirem conexões para a rede só em SSH (`22`) e apiserver (`6443`), mais ICMP; etcd, kubelet e o resto ficam
  fechados para eles. No sentido contrário nada passa: um pod comprometido não alcança o laptop de um operador.
- **PROXY protocol restrito**: o Traefik só aceita o cabeçalho vindo de `network_cidr`, para que ninguém forje
  o IP de origem.
- **external-dns com escopo**: `domainFilters` é obrigatório (uma lista vazia seria rejeitada), e o registro
  TXT de dono impede que ele apague registros alheios.
- **Proteção contra deleção** em etcd, IP da VPN e rede ([ADR 0013](adr/0013-delete-protection.md)).
- **CI sem credenciais** ([ADR 0015](adr/0015-static-only-ci.md)), com trivy procurando misconfigurações
  HIGH/CRITICAL.

## Riscos conhecidos

- **Gateway é ponto único de falha** para VPN, egress e joins. Nós já no cluster seguem funcionando, porque
  falam direto com os masters.
- **Tokens no metadata service**: o user_data dos masters tem o token de server, e o dos workers tem o agent
  token. Pods comuns são bloqueados pelo tier `metadata-guard` do Calico
  ([ADR 0017](adr/0017-block-instance-metadata-for-pods.md)). Ainda leem: o `hcloud-csi` (exceção) e pods com
  `hostNetwork`, que só podem existir no `kube-system`.
- **Provider Karpenter comunitário**: tem acesso total ao token da Hetzner. A versão do chart é fixada, e
  upgrades devem ser revisados.
- **R2 sem versionamento**: um state corrompido ou sobrescrito se recupera pelos backups (`state-backups/` local e `rke2-tfstate/backups/`). Os dois ficam ao alcance do token do state, que já lê tudo.
