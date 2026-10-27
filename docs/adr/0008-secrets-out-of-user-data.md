# 0008. Tokens separados e segredos fora do user_data

- **Status:** Aceito
- **Commits:** `83c7e4a`

## Contexto

O user_data de um servidor Hetzner pode ser lido pelo metadata service (`169.254.169.254`) por qualquer
processo no nó, **inclusive pods**. Na versão inicial, os workers recebiam o token de server do RKE2 e o Secret
do token da Hetzner era criado por um manifest no cloud-init dos masters.

## Decisão

- **Dois tokens RKE2:** `token`, conhecido só pelos masters, e `agent-token`, que só permite entrar como agente.
  Os workers recebem apenas o `agent-token`, pelo output `worker_user_data` → Secret
  `karpenter-worker-bootstrap` → `HCloudNodeClass.userDataSecretRef`.
- **Token da Hetzner fora de qualquer user_data:** o Secret `kube-system/hcloud` (token + ID da rede) é criado
  pelo root `terraform/cluster`. CCM e CSI esperam por ele.
- O userData dos workers fica num Secret referenciado pela NodeClass, não inline no spec.

## Alternativas consideradas

- **Token único:** um pod comprometido num worker conseguiria entrar no cluster como server e ler o etcd.
- **Bloquear o metadata service e manter tudo no user_data:** depende de uma network policy que pode faltar ou
  ser removida. Fica como defesa adicional, não como a primária.

## Consequências

- Os nós ficam `uninitialized` até o root `cluster` ser aplicado. Essa é a dependência de bootstrap documentada.
- O vazamento do userData de um worker permite, no pior caso, registrar um nó agente falso, sem acesso ao etcd ou
  à API da Hetzner.
- Risco residual: o `agent-token` continua legível pelo metadata service. Mitigação sugerida: uma
  `GlobalNetworkPolicy` do Calico bloqueando o egress de pods para `169.254.169.254`.
