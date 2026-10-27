# 0022. Backup de objetos e volumes com Velero no R2

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/velero.tf`

## Contexto

Os snapshots do etcd ([ADR 0019](0019-etcd-snapshots-r2.md)) restauram o control plane inteiro, mas não os dados
dos volumes (Hetzner Volumes do CSI) e não permitem recuperar um namespace apagado sem voltar o cluster todo.

## Decisão

- **Velero** no namespace `velero`, com o plugin AWS apontado para o bucket R2 `rke2-velero` (pasta =
  `cluster_name`). Bucket e token (Object Read & Write só nesse bucket) são criados pelo Terraform, como os do
  etcd, e o bucket tem `prevent_destroy`.
- **Volumes por arquivo** (node agent com kopia): o CSI da Hetzner não tem snapshots que o Velero use.
  `defaultVolumesToFsBackup` copia todo volume montado.
- **Agenda diária** às 23:00 (São Paulo), antes da janela do kured, com 7 dias de retenção. O namespace
  `monitoring` fica de fora: é todo recriado pelo Terraform, e o TSDB do Prometheus dominaria o backup.
- **Alertas:** `VeleroBackupFailed` e `VeleroNoRecentBackup` (nenhum backup bem-sucedido em 36 h) vão para o
  Telegram ([ADR 0021](0021-monitoring-telegram.md)).
- O namespace `velero` é `privileged`: o node agent lê os volumes pelo `hostPath` do kubelet.

## Alternativas consideradas

- **Só o etcd:** não cobre dados de volumes.
- **Snapshots de volume da Hetzner:** a API de Volumes da Hetzner não tem snapshots.

## Consequências

- O backup por arquivo não é consistente no nível de aplicação: bancos de dados precisam de dump próprio (hooks
  do Velero ou backup nativo do banco).
- O node agent roda em todos os workers.
