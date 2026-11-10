# 0031. PostgreSQL com o CloudNativePG

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/postgres.tf terraform/cluster/charts/pg-cluster`

## Contexto

O Harbor ([ADR 0033](0033-harbor-registry.md)) precisa de PostgreSQL. O chart dele traz um Postgres próprio, de
uma instância, sem backup fora do volume e sem failover. Outros serviços com Postgres virão. Como no MongoDB
([ADR 0030](0030-mongodb-percona-operator.md)), os nós são arm64 e trocados pelo Karpenter, e o banco precisa de
failover automático e backup no R2 com restore a um ponto no tempo.

## Decisão

- **CloudNativePG** (chart `cloudnative-pg`, operator 1.30) no namespace `cnpg-system`, vigiando todos os
  namespaces: cada banco vive no namespace do app que o usa, e o Secret `<cluster>-app` que o operator gera
  (usuário, senha, host, URI) fica ao lado do app, sem cópia entre namespaces.
- **Backups pelo plugin Barman Cloud** (chart `plugin-barman-cloud`, no mesmo namespace do operator, com
  certificados do cert-manager), e não pelo `barmanObjectStore` embutido, que está deprecado. Um bucket R2,
  `rke2-postgres` (`prevent_destroy`, token só nele), com uma pasta por cluster: WAL contínuo (PITR) e um backup
  base diário, retenção de 14 dias.
- **Um chart local, `charts/pg-cluster`**, cria por banco o `ObjectStore`, o `Cluster`, o `ScheduledBackup` e o
  PodMonitor ([ADR 0014](0014-local-helm-charts-for-crds.md): os CRs não podem ser planejados antes de as CRDs
  existirem). Cada consumidor instala uma release dele no próprio namespace, com o Secret de credenciais do R2.
  Padrões: PostgreSQL 17 (imagem `standard`, multi-arch), 2 instâncias (primária e réplica) em locations
  diferentes, PDB, 10 GB.
- **Sem PgBouncer por padrão.** Um `Pooler` em modo `transaction` quebra clientes que usam prepared statements
  (o Harbor usa). Um consumidor que precise de pool cria o seu.
- **Velero não copia os volumes do Postgres** (anotação nos pods via `inheritedMetadata`): a cópia por arquivo
  de um Postgres rodando não é consistente, e o Barman cobre os dados.
- Métricas pelo exporter embutido em cada instância (PodMonitor do chart local), alertas de WAL sem arquivar,
  backup atrasado e réplica atrasada, e o dashboard oficial no Grafana.

## Alternativas consideradas

- **Percona Operator for PostgreSQL:** também multi-arch e com pgBackRest e PITR, mas traz Patroni, pgBouncer e
  pgBackRest como peças separadas por cluster. O CloudNativePG é mais leve, é projeto da CNCF e gerencia o
  failover sem Patroni.
- **Postgres do chart de cada app:** uma instância, sem PITR, um jeito diferente por app.
- **Zalando postgres-operator:** maduro, mas com Spilo e WAL-G, menos ativo e sem o modelo de plugins de backup.

## Consequências

- O operator e o plugin pedem ~150 Mi de memória. Cada banco com os padrões ocupa dois nós (anti-afinidade por
  location) e dois volumes de 10 GB.
- Com duas instâncias, perder a primária promove a réplica em segundos; perder as duas exige restore do R2.
- Restore é um `Cluster` novo com `bootstrap.recovery` apontando para o `ObjectStore` (backup ou ponto no tempo),
  descrito em `docs/operations.md`.
- O chart local precisa de `version` novo no `Chart.yaml` a cada mudança de template, como o `charts/nodepools`.
- O bucket `rke2-postgres` tem o conteúdo de todos os bancos Postgres e é tão sensível quanto eles.
