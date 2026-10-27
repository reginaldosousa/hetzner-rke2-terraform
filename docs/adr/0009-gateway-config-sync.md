# 0009. Configuração do gateway sincronizada in-place, fail-closed, com host key fixada

- **Status:** Aceito
- **Commits:** `e3a08ee`, `dccce7e`, `5f5081d`

## Contexto

Adicionar um cliente VPN mudava o `user_data` do gateway e forçava um rebuild, derrubando VPN, egress e o
endpoint do control plane. Com `ignore_changes = [user_data]`, o rebuild deixa de acontecer, mas uma
**revogação** de peer passa a depender de alguém lembrar de rodar um script. Uma chave revogada continuaria
funcionando em silêncio. Além disso, o script envia a chave privada do WireGuard por SSH: com
`accept-new` e a VPN caída, numa LAN que também use `10.0.x.x`, ele poderia confiar em outro host e entregar a
chave.

## Decisão

1. **Arquivos mutáveis isolados:** `wg0.conf`, `nftables.conf` e `haproxy.cfg` são renderizados uma vez em
   `local.gateway_files`. O cloud-init os grava no primeiro boot, e o gateway ignora mudanças de `user_data`.
2. **Sync in-place:** `scripts/sync-gateway.sh` faz o diff (com chaves ocultadas), envia por stdin do SSH,
   **valida no gateway** (`nft -c`, `haproxy -c`, `wg-quick strip`) e só então ativa sem interrupção: swap
   atômico do nft, reload gracioso do HAProxy e `wg syncconf`.
3. **Fail-closed:** `terraform_data.gateway_sync` roda o script em todo apply que muda esses arquivos ou recria o
   gateway. Se o envio falhar, o apply falha e o recurso fica tainted, então o próximo apply tenta de novo. Os
   arquivos desejados vão por `GATEWAY_FILES_JSON`, porque `terraform output` está desatualizado durante o apply.
   Só o primeiro bootstrap usa `-var gateway_sync=false`.
4. **Host key fixada:** `tls_private_key.gateway_host` (ED25519) é instalada pelo cloud-init. O script conecta
   apenas com `StrictHostKeyChecking=yes` contra o output `gateway_known_hosts`, nunca trust-on-first-use.

## Alternativas consideradas

- **Recriar o gateway a cada mudança:** simples, mas causa downtime de VPN, egress e joins a cada cliente novo.
- **Script manual sem provisioner:** sem falha visível, e a revogação poderia ser esquecida.
- **Ferramenta de configuração (Ansible):** mais uma ferramenta e inventário para três arquivos.
- **`accept-new` no SSH:** cômodo, mas vulnerável no primeiro contato.

## Consequências

- Adicionar ou remover clientes VPN e mudar masters não reconstrói o gateway, e os túneis existentes continuam.
- Todo `apply` do `infra` que mexe no gateway **exige a VPN ativa**.
- Trocar a host key exige instalá-la primeiro no gateway, pela conexão já confiável.
- `scripts/sync-gateway.sh --dry-run` detecta drift manual.

## Atualizações
- **2026-10-27:** Os masters seguem o mesmo princípio: `scripts/pin-master-host-keys.sh` lê as host keys deles pelo
  gateway (já fixado) e grava `master_known_hosts`, e `get-kubeconfig.sh` e `sync-masters.sh` só conectam com
  `StrictHostKeyChecking=yes`. A configuração do RKE2 nos masters tem um sync próprio, manual
  ([0018](0018-pod-security-baseline.md)).
