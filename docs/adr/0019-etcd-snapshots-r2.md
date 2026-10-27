# 0019. Snapshots do etcd no Cloudflare R2

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/etcd-snapshots.tf`

## Contexto

O RKE2 tira snapshots do etcd a cada 12 h e guarda 5, só no disco local de cada master
(`file:///var/lib/rancher/rke2/server/db/snapshots`, confirmado em 2026-10-27). Os três masters ficam na mesma
localização (`nbg1`). Perder os três, por falha da localização, deleção acidental ou um erro de operação no
etcd, perde o cluster sem cópia para restaurar. O R2 já guarda o state do Terraform na mesma conta.

## Decisão

- Os masters rodam com `etcd-s3: true` e `etcd-s3-config-secret: rke2-etcd-snapshot-s3`, num drop-in do RKE2
  ([ADR 0018](0018-pod-security-baseline.md)). Snapshot a cada 6 h, comprimido, 28 cópias locais e 28 no R2 por
  master (7 dias).
- Endpoint, bucket (`rke2-etcd-snapshots`, pasta = `cluster_name`), credenciais e retenção ficam no Secret
  `kube-system/rke2-etcd-snapshot-s3`, criado pelo root `terraform/cluster`. O RKE2 lê esse Secret a cada
  snapshot, então ele não precisa existir no boot (mesmo padrão do Secret `hcloud`).
- O bucket e as credenciais são criados pelo próprio Terraform (provider `cloudflare`, root `cluster`): um
  token de conta com `Workers R2 Storage Bucket Item Write` **só** nesse bucket, separado do token do state. As
  credenciais S3 são derivadas do token (id e sha256 do valor) e vão direto para o Secret. O bucket tem
  `prevent_destroy`.
- O provider usa `cloudflare_provisioning_api_token` (R2 Storage: Edit e Account API Tokens: Edit), que fica só
  no `terraform.tfvars` do operador e nunca entra no cluster.

## Alternativas consideradas

- **Credenciais S3 no drop-in do master:** iriam para o user_data de masters novos, que pods conseguiriam ler
  ([ADR 0008](0008-secrets-out-of-user-data.md)).
- **Mesmo bucket do state:** um token vazado do cluster daria acesso ao state, que tem todos os segredos.
- **Bucket e token criados à mão no painel:** passo manual sem registro, e a rotação dependeria de alguém
  lembrar de atualizar o tfvars.
- **Velero:** faz backup de objetos da API e volumes, mas não substitui o snapshot do etcd para recuperar o
  control plane. Pode vir depois, para os volumes.

## Consequências

- O restore exige o **token de server** do RKE2 da época do snapshot (ele decifra os dados de bootstrap). Esse
  token está no state do `infra` (`random_password.rke2_token`), então perder o state e os backups dele também
  inutiliza os snapshots.
- O restore não usa o Secret: as opções `etcd-s3-*` vão na linha de comando (ver `docs/operations.md`).
- Os snapshots têm todo o conteúdo do cluster. Os Secrets estão cifrados pelo `secrets-encryption` do RKE2, mas
  o resto (ConfigMaps etc.) não. O bucket deve ser tratado como sensível.
