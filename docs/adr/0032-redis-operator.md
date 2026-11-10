# 0032. Redis com o operator da OT-Container-Kit

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/redis-operator.tf`

## Contexto

O Harbor ([ADR 0033](0033-harbor-registry.md)) usa Redis para cache, fila de jobs e sessões, e o chart dele traz
um Redis próprio. Depois virão serviços do Tsuru ([ADR 0034](0034-tsuru-paas.md)) que entregam Redis aos apps.
Como no MongoDB e no Postgres ([ADR 0030](0030-mongodb-percona-operator.md),
[ADR 0031](0031-postgres-cloudnativepg.md)), queremos um jeito só de rodar cada tipo de banco, com failover, em
imagens arm64. Em 2026-11 havia:

- `valkey-io/valkey-operator` (v0.8, oficial do Valkey): o README diz "not ready for production use", API
  `v1alpha1`.
- `OT-CONTAINER-KIT/redis-operator` (v0.27, Apache 2.0): maduro, imagens multi-arch, CRDs para Redis
  standalone, replicação com Sentinel e cluster. Valkey só no roadmap.
- O serviço de Redis do próprio Tsuru (`tsuru/redisapi`) está arquivado.

## Decisão

- **OT-Container-Kit redis-operator** (chart `redis-operator`) no namespace `redis-operator`, com escopo de
  cluster: cada instância vive no namespace de quem a usa. Webhook desligado.
- **Instâncias pelos charts da própria OT-Container-Kit** (`redis-replication`, `redis`), que só renderizam os
  CRs. O padrão para quem precisa de alta disponibilidade é `RedisReplication` (primária + réplica) com Sentinel.
- **Imagens de Redis pinadas na série 7.2** (`quay.io/opstree/redis:v7.2.x`), a última sob licença BSD. O Redis
  7.4 passou para RSAL/SSPL e o 8 para AGPL.
- Redis aqui é cache: sem persistência e fora do Velero por padrão. Quem precisar de dado durável pede
  persistência e backup explicitamente.
- Métricas do operator por PodMonitor; cada instância liga o `redis-exporter` do próprio CR.

## Alternativas consideradas

- **Redis do chart de cada app:** uma instância por app, cada uma configurada de um jeito, sem failover.
- **valkey-operator oficial:** é o caminho natural quando sair do alpha. Trocar quando ele chegar a beta, ou
  quando o operator da OT-Container-Kit suportar Valkey.
- **Bitnami Redis:** as imagens da Bitnami deixaram de ser públicas.
- **Redis Enterprise operator:** licença comercial.

## Consequências

- O operator pede ~64 Mi. Uma `RedisReplication` com Sentinel são 5 pods pequenos (2 Redis, 3 Sentinel).
- Ficamos no Redis 7.2, que não recebe novidades: a saída é o Valkey (fork BSD do 7.2), quando houver um operator
  maduro para ele.
- Entregar Redis como serviço do Tsuru (`tsuru service-instance-add`) ainda precisa de um broker que crie os CRs:
  fica para um PR futuro.
