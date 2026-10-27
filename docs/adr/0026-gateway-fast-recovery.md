# 0026. Gateway descartável: recuperação rápida em vez de HA

- **Status:** Aceito
- **Commits:** `4861cbc`, `abcda05`, `f34b92f`

## Contexto

O gateway é ponto único de falha para o NAT de saída dos nós, o HAProxy do control-plane (kubectl e join de
nós novos, ou seja, o Karpenter), o Headscale e o WireGuard ([ADR 0003](0003-private-network-wireguard-gateway.md),
[0004](0004-haproxy-control-plane-endpoint.md), [0025](0025-headscale-oidc-vpn.md)). Quase tudo nele já sai do
Terraform e volta num `apply -replace`, menos o estado do Headscale: as chaves Noise e DERP e o banco SQLite com
usuários e nós. Num rebuild a tailnet inteira se perdia e cada usuário refazia o `tailscale up`.

## Decisão

Aceitamos alguns minutos de indisponibilidade do gateway e tornamos o rebuild completo e sem perda:

- **Chaves do Headscale no Terraform** (`random_bytes`), entregues como os demais arquivos do gateway. O
  `sync-gateway.sh` não mostra o conteúdo e **recusa trocar uma chave viva diferente**: chave não importada falha o
  apply em vez de forçar todos os clientes a se registrarem de novo.
- **Litestream** (v0.5.17, `.deb` conferido por sha256) replica o SQLite continuamente para o bucket R2
  `rke2-headscale`, com token que só lê e escreve objetos nele. O bucket e o token vêm do `terraform/cluster`
  (o `infra` não fala com a Cloudflare) e chegam ao `infra` pela variável `headscale_backup`.
- **Restore uma vez por host**, no instalador, antes de Headscale e Litestream escreverem: se há cópia no R2, ela
  substitui o banco local. O gateway que inicia o backup não acha cópia e mantém o seu. Um marcador
  (`/var/lib/headscale/.restore-done`) impede restores posteriores.
- **Detecção:** gateway fora do ar corta a saída do Alertmanager, então o dead man's switch (Watchdog) avisa
  ([ADR 0021](0021-monitoring-telegram.md)). Nenhum alerta novo.

## Alternativas consideradas

- **Dois gateways com keepalived e Floating IP** (failover em segundos): mais um servidor e um Floating IP (cerca de
  US$ 10/mês), e um token da API da Hetzner com escrita no projeto inteiro dentro do host público, porque a rede
  privada não tem VRRP e o failover move IP e rotas pela API. Continua possível depois: chaves no Terraform e
  banco no R2 são pré-requisitos dele.
- **Load Balancer da Hetzner para o control-plane:** cobre só o HAProxy; NAT e VPN seguem no gateway.
- **Headscale no cluster:** a VPN cairia junto com o cluster ([ADR 0025](0025-headscale-oidc-vpn.md)).
- **Backup periódico (tar do diretório) em vez de Litestream:** perde até um intervalo inteiro de registros.

## Consequências

- RTO de um rebuild: cerca de 3 minutos no teste de 2026-10-27, com a tailnet voltando sozinha;, RPO de segundos para a tailnet. Durante o rebuild os nós ficam
  sem egress e não entra nó novo; os nós já no cluster seguem funcionando.
- O certificado TLS do Headscale é reemitido pelo ACME a cada rebuild (o cache não é copiado).
- O gateway antigo continua no banco restaurado como nó offline; apague-o depois do rebuild.
- O gateway passa a ter credenciais de escrita no bucket `rke2-headscale` (o R2 não tem versionamento): quem
  tomar o gateway pode apagar a cópia, mas não o banco vivo.
- Ativar o backup exige importar as chaves vivas uma vez (`docs/operations.md`).
- Vale olhar as operações classe A do R2 depois da primeira semana, porque o Litestream escreve a cada mudança.
