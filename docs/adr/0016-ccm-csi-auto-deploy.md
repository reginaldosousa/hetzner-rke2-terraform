# 0016. CCM e CSI via auto-deploy manifests do RKE2

- **Status:** Aceito
- **Commits:** `9552db3`, `c314ffb`, `83c7e4a`

## Contexto

Com `cloud-provider-name: external`, os nós nascem com o taint `node.cloudprovider.kubernetes.io/uninitialized`
até um CCM inicializá-los. O CCM precisa estar no cluster **antes** de qualquer outro workload, inclusive antes
de o root `terraform/cluster` existir. O Karpenter exige `providerID: hcloud://<id>`.

## Decisão

O cloud-init dos masters grava `/var/lib/rancher/rke2/server/manifests/hcloud.yaml` com dois `HelmChart`
(controller do RKE2), em versões fixadas:

- **hcloud-cloud-controller-manager** com `bootstrap: true` (roda em nó não inicializado) e `networking.enabled`.
  - `HCLOUD_NETWORK_ROUTES_ENABLED=false`: o Canal é overlay e não precisa de rotas por nó.
  - `HCLOUD_INSTANCES_ZONE_LABEL_ENABLED=false`: o label de zona fica com o Karpenter.
  - `HCLOUD_LOAD_BALANCERS_LOCATION` e `..._USE_PRIVATE_IP=true` como padrão para LBs.
- **hcloud-csi** para a StorageClass `hcloud-volumes`.

O Secret `kube-system/hcloud` que eles consomem é criado pelo root `cluster` ([0008](0008-secrets-out-of-user-data.md)).
O CCM interno do RKE2 é desligado (`disable-cloud-controller: true`).

## Alternativas consideradas

- **`helm_release` no root `cluster`:** funcionaria, mas os nós ficariam sem CCM se o `cluster` falhasse, e
  instalaria um componente de bootstrap a partir de uma camada que depende dele.
- **CCM interno do RKE2:** define um `providerID` `rke2://` imutável, incompatível com o Karpenter.

## Consequências

- CCM e CSI sobem junto com o control plane, sem passo manual.
- Os nós ficam `uninitialized` até o Secret existir. Isso é esperado no bootstrap.
- Como os masters ignoram mudanças de `user_data`, upgrades de versão do CCM/CSI exigem editar o manifest em
  cada master (ver [operations.md](../operations.md#upgrades)).
