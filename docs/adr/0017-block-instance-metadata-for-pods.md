# 0017. Pods bloqueados no metadata service por um tier do Calico

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/metadata-guard.tf`

## Contexto

O metadata service da Hetzner (`169.254.169.254`) entrega o user_data do servidor a qualquer processo no nó,
inclusive pods. O [ADR 0008](0008-secrets-out-of-user-data.md) tirou o token da Hetzner do user_data e deu só o
`agent-token` aos workers, mas o user_data dos **masters** ainda contém o `token` de server do RKE2 (confirmado
em 2026-10-27: `curl 169.254.169.254/hetzner/v1/userdata` num master retorna os dois tokens). Qualquer pod
agendado num master, como um DaemonSet que tolera todos os taints, consegue esse token e entra no cluster como
server com etcd. Nos workers, o `agent-token` permite registrar um nó falso.

O CNI é o Canal (Calico 3.32 para policy). Uma GlobalNetworkPolicy no tier `default` que seleciona todos os
pods transformaria em deny todo egress que nenhuma regra permite, porque o tier `default` termina em deny
implícito.

## Decisão

Usamos um Tier próprio, `metadata-guard` (order 100, antes do `default`), com `defaultAction: Pass`, e nele uma
GlobalNetworkPolicy que nega egress para `169.254.169.254/32` a todos os pods, exceto o `hcloud-csi` em
`kube-system`, que lê o ID do servidor no metadata. O que a policy não nega segue para o tier `default`, onde
valem as NetworkPolicies normais. Ambos são criados pelo root `terraform/cluster` (`metadata-guard.tf`).

## Alternativas consideradas

- **GlobalNetworkPolicy no tier `default` com Allow final:** o Allow anularia o default-deny das NetworkPolicies
  de egress dos namespaces.
- **Regra nftables em cada nó (forward → 169.254.169.254):** não permite exceção por pod, quebrando o CSI, e
  exige mudar cloud-init de masters e workers e empurrar a regra para os nós existentes.
- **Rotacionar o token de server depois do bootstrap:** masters novos precisam do token do user_data, então o
  Terraform teria que acompanhar a rotação. O bloqueio resolve sem isso.

## Consequências

- Pods fora da exceção não leem mais nenhum user_data. A exceção (CSI, privilegiado de qualquer forma) e pods com
  `hostNetwork` continuam lendo. Por isso a policy depende de Pod Security impedir `hostNetwork` fora do
  `kube-system` ([ADR 0018](0018-pod-security-baseline.md)).
- Um componente novo que precise do metadata (raro, porque a maioria usa a API) precisa entrar no seletor de
  exceção.
- Teste depois de cada mudança: de um pod em `default`, `curl -m3 169.254.169.254/hetzner/v1/metadata/instance-id`
  deve falhar, e `curl -sI https://get.rke2.io` deve funcionar.
