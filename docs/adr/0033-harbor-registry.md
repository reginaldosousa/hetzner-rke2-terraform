# 0033. Harbor como registry de imagens

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/harbor.tf terraform/registry`

## Contexto

O Tsuru ([ADR 0034](0034-tsuru-paas.md)) constrói as imagens dos apps e precisa de um registry para enviá-las, e os
nós precisam baixá-las de lá. O registry tem que funcionar só pela rede privada e pela VPN, como as outras
aplicações internas ([ADR 0027](0027-internal-apps-dns.md)). Mas os nós resolvem DNS pelos servidores da Hetzner e
não enxergam a zona interna (`int.devcomm.com.br`), que só o dnsmasq do gateway responde. O kubelet não conseguiria
baixar de um registry com nome nessa zona.

Os workers são arm64. O Harbor só publica imagens arm64 a partir da v2.16.0 (2026-11-10), e o chart oficial
ainda estava no 1.19.4 (Harbor 2.15.4, só amd64).

## Decisão

- **Harbor** no namespace `harbor`, chart oficial `goharbor/harbor` 1.19.4 com todas as imagens em **v2.16.0**
  (`harbor_version`) até sair o chart da 2.16. A única diferença do `main` do chart para o 1.19.4 são campos
  novos de Gateway API, que não usamos.
- **Nome público, endereço privado:** `harbor.devcomm.com.br` (fora da zona interna) é um registro A público que
  aponta para o IP do **LB interno** (`internal_ingress_ip`). Nós, pods e clientes da VPN resolvem o nome; só a
  rede privada e a tailnet alcançam o IP. O Ingress fica só no entrypoint `internal`. O external-dns publica o
  registro com a anotação `target`, e não com o IP público do status do Ingress. O certificado é um Let's
  Encrypt próprio, por DNS-01.
- **Banco no CloudNativePG** ([ADR 0031](0031-postgres-cloudnativepg.md)): `harbor-db`, uma release do
  `charts/pg-cluster` no namespace `harbor` (2 instâncias, PostgreSQL 17), e o Harbor lê o Secret `harbor-db-app`.
  Conexão direta no `harbor-db-rw`, sem PgBouncer, e com no máximo 50 conexões por pod.
- **Redis do operator** ([ADR 0032](0032-redis-operator.md)): `harbor-redis`, uma `RedisReplication` (primária +
  réplica, Redis 7.2) com Sentinel, sem volume. O Harbor usa o Service `harbor-redis-master`, que o operator
  move para a nova primária quando o Sentinel promove a réplica. Usar o Sentinel direto no Harbor seria pior: o
  cliente de cada componente trata Sentinel de um jeito, e nenhum autentica no Sentinel.
- **Imagens no R2** (bucket `rke2-harbor`, token só nele), pelo driver S3 do registry, com `disableredirect`: o
  cliente baixa pelo Harbor, não por URL assinada do R2.
- **Segredos estáveis pelo Terraform:** senha do admin, `secretKey` (cifra as credenciais guardadas no banco) e a
  credencial interna do registry vêm de `random_password`. Os demais segredos internos o chart preserva com
  `lookup`.
- **Configuração como código num root novo, `terraform/registry`** (provider `goharbor/harbor`, versão exata):
  login OIDC pelo Pocket ID (client `harbor` no root `identity`, grupo `k8s-admins` vira admin do Harbor), projeto
  privado `tsuru`, retenção (10 artefatos mais recentes por repositório), garbage collection semanal e um robot
  account `tsuru` com push e pull nesse projeto. É um root separado pelo mesmo motivo do `identity`: o provider
  precisa do Harbor no ar e da senha de admin.
- **Trivy** ligado (a imagem 2.16 é multi-arch), com cache de 10 GB. Métricas por ServiceMonitor. Logs dos jobs
  no stdout, então vão para o Loki ([ADR 0029](0029-observability-opentelemetry.md)).

## Alternativas consideradas

- **Registry na zona interna (`harbor.int.devcomm.com.br`):** os nós não resolvem a zona. Seria preciso DNS
  dividido nos nós (systemd-resolved apontando para o gateway) e um stub no CoreDNS, mudando o infra e os
  masters. Um nome público com IP privado resolve o mesmo problema sem mexer nisso.
- **Harbor público:** expõe login e API à internet. Os pulls dos nós sairiam pelo NAT e voltariam pelo LB
  público.
- **Node pool amd64 para o Harbor:** mais um tipo de nó só para esperar o chart.
- **Postgres e Redis do próprio chart:** um pod de cada, sem failover e sem backup do banco fora do volume.
- **Registry simples (`distribution`) ou o Zot:** sem projetos, robots, OIDC, retenção e scan, que o Tsuru e
  os times vão precisar.

## Consequências

- O registro A público revela um IP privado (`10.0.1.x`), o que não dá acesso a nada. Resolvedores que bloqueiam
  IP privado em resposta pública (proteção contra DNS rebinding) quebram o nome. Os clientes da VPN usam o DNS da
  tailnet, que não bloqueia.
- O chart fica num estado provisório: quando sair o chart da 2.16, troca-se `harbor_chart_version` e
  remove-se o override de imagens.
- ~2,5 GB de memória (core, jobservice, portal, registry, Trivy, exporter, Redis e Postgres) e três volumes de
  10 GB (Trivy e as duas instâncias do Postgres).
- O token interno que o core assina é recriado a cada upgrade do chart (o chart gera um certificado novo). Isso
  derruba sessões de `docker login` no meio do upgrade, sem perder dado.
- O bucket `rke2-harbor` tem todas as imagens e é tão sensível quanto o código delas.
- Quando a primária do Redis cai, o Sentinel promove a réplica em segundos, mas o Service `harbor-redis-master`
  fica sem endpoints até o operator trocar o label (~35-40 s, medido no teste do operator em 2026-11-10). Nesse
  intervalo, login e jobs do Harbor falham e pulls de imagens já em cache seguem. Se isso incomodar, a troca é
  apontar o Harbor para o Sentinel (`harbor-redis-s-hl:26379`, `sentinelMasterSet: mymaster`).
