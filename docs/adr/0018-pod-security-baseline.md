# 0018. Pod Security `baseline` por padrão, com drop-ins do RKE2 sincronizados nos masters

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/infra/templates/master scripts/sync-masters.sh`

## Contexto

Sem `profile: cis`, o RKE2 gera `/etc/rancher/rke2/rke2-pss.yaml` com `enforce: privileged`, e nenhum namespace
tinha rótulo `pod-security.kubernetes.io/*`. Qualquer namespace podia criar pods privilegiados, com `hostPath` ou
`hostNetwork`: root no nó, e o `hostNetwork` também passa por cima do bloqueio de metadata do
[ADR 0017](0017-block-instance-metadata-for-pods.md).

Os masters ignoram mudanças de `user_data` ([ADR 0013](0013-delete-protection.md), etcd mora neles), então uma
mudança de configuração do RKE2 no cloud-init só valeria para masters novos.

## Decisão

- O apiserver usa `/etc/rancher/rke2/pod-security.yaml`: `enforce: baseline` por padrão, `audit`/`warn` em
  `restricted`, e `kube-system` isento (CNI, CSI, CCM, Karpenter, Traefik).
- Configurações do RKE2 que precisam chegar aos masters em execução viram arquivos em
  `/etc/rancher/rke2/config.yaml.d/` (`local.master_files` em `masters.tf`, output `master_config_files`). O
  cloud-init os grava em masters novos, e `scripts/sync-masters.sh` os envia aos existentes, reiniciando o
  `rke2-server` **um master por vez**. O script espera `/readyz` (que inclui o etcd local) antes de passar ao
  próximo e para no primeiro que não voltar.
- Esses arquivos não têm segredos. O script conecta só com as host keys de `master_known_hosts`, lidas pelo
  gateway (`pin-master-host-keys.sh`).

## Alternativas consideradas

- **`profile: cis`:** exige usuário `etcd`, sysctls e PSA `restricted` em tudo. É mais do que o cluster precisa
  agora e quebraria componentes que hoje rodam fora do `kube-system`.
- **Rótulos por namespace no Terraform:** cada namespace novo nasceria `privileged` até alguém lembrar de rotular.
  O padrão precisa ser seguro.
- **Rodar o sync no `terraform apply`, como o do gateway:** reiniciar o control plane durante um apply é
  arriscado demais para acontecer como efeito colateral. O sync é manual, com `--dry-run`.

## Consequências

- Workloads que precisam de privilégio (node-exporter, agentes de log) exigem um namespace com
  `pod-security.kubernetes.io/enforce=privileged` explícito, uma decisão visível no código.
- Quem pode editar rótulos de namespace pode afrouxar o nível. RBAC deve limitar isso quando houver mais usuários.
- Depois de um `apply` do `infra` que mude `master_config_files`, é obrigatório rodar `scripts/sync-masters.sh`.
  O `--dry-run` mostra o drift.
