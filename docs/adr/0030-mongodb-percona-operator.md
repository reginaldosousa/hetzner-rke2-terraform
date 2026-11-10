# 0030. MongoDB com o Percona Operator

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/mongodb.tf`

## Contexto

O Tsuru (PaaS que vem depois, [ADR 0034](0034-tsuru-paas.md)) guarda tudo num MongoDB. O chart `tsuru-stack`
traz um MongoDB da Bitnami com senhas fixas, sem réplica e sem backup. Os workers são arm64 (`cax`,
[ADR 0010](0010-arm64-cax.md)) e trocados pelo Karpenter a qualquer hora (consolidação, `expireAfter` de 30 dias),
então o banco precisa sobreviver à perda de um nó sem intervenção e ter backup fora do cluster.

## Decisão

- **Percona Operator for MongoDB** (chart `psmdb-operator`, 1.23.x) no namespace `mongodb`, vigiando só ele.
  O cluster é criado pelo chart `psmdb-db`, que só renderiza o CR `PerconaServerMongoDB` (o Helm instala depois
  que o operator criou a CRD, sem chart local).
- **Replica set `rs0` de 3 membros** (Percona Server for MongoDB 8.0, imagem multi-arch), um por nó
  (anti-afinidade por hostname) e espalhados pelas locations do `worker_locations`, volumes de 10 GB, PDB de
  no máximo um indisponível. Sem sharding.
- **Backups com o Percona Backup for MongoDB** no bucket R2 `rke2-mongodb` (`prevent_destroy`, token só nele,
  como o Loki e o Velero): lógico diário com 7 cópias, mais **PITR** (oplog contínuo), para voltar a qualquer
  ponto dos últimos 7 dias.
- **Usuários de aplicação pelo CR** (`spec.users`), com a senha num Secret gerado pelo Terraform
  (`random_password`). O primeiro é `tsuru` (`readWrite` em `tsuru`); a URI dele é um output sensível.
- **Métricas:** sidecar `mongodb_exporter` em cada membro, com o usuário de monitoramento que o operator gera,
  um PodMonitor e alertas de membro fora do ar e de replica set sem primário.
- **Velero não copia os volumes do Mongo** (anotação `backup.velero.io/backup-volumes-excludes` nos pods): uma
  cópia de arquivos de um mongod rodando não é consistente, e o PBM já cobre os dados.
- TLS no modo `preferTLS` (padrão do operator, certificados pelo cert-manager): os membros falam TLS entre si e
  os clientes podem usar TLS. Upgrades automáticos de versão desligados (versões pinadas no Terraform).

## Alternativas consideradas

- **MongoDB do `tsuru-stack` (Bitnami):** um pod só, senha fixa `tsuru`, sem backup; as imagens da Bitnami
  deixaram de ser públicas.
- **HelmForge `mongodb`:** replica set, mas backup só por `mongodump` diário (sem PITR), upgrades e mudanças de
  topologia manuais, e mantido por uma pessoa.
- **Operator oficial da MongoDB (`mongodb-kubernetes`, edição community):** gerencia o replica set, mas não tem
  backup; teríamos de montar um.
- **MongoDB fora do cluster (Atlas):** latência e custo fora da Hetzner, e o dado sai da rede privada.

## Consequências

- ~3 GB de memória a mais (1 GB por membro) e três volumes de 10 GB. Os membros ocupam três workers distintos,
  o que, somado ao resto, faz o Karpenter subir mais nós.
- Com duas locations, uma fica com dois membros. Perder essa location derruba o primário até ela voltar: o
  replica set aguenta a perda de um nó, não de uma location inteira.
- O bucket `rke2-mongodb` passa a ser tão sensível quanto os dados das aplicações do Tsuru.
- Restaurar é pelo CR `PerconaServerMongoDBRestore` (backup ou ponto no tempo), descrito em
  `docs/operations.md`. Um restore pede o replica set parado para escrita.
- Upgrade do Percona Server ou do operator é uma mudança de variável no Terraform, revisada no plan.
