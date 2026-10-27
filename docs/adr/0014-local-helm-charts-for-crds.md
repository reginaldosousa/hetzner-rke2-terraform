# 0014. Recursos que dependem de CRDs em charts Helm locais

- **Status:** Aceito
- **Commits:** `216931d`, `f043dc4`

## Contexto

`HCloudNodeClass`/`NodePool` (Karpenter) e `ClusterIssuer` (cert-manager) são CRDs instalados por releases Helm
do próprio root `cluster`. O `kubernetes_manifest` consulta o schema do CRD **na fase de plan**, então falha num
cluster onde o CRD ainda não existe.

## Decisão

Esses recursos ficam em charts Helm locais, instalados com `helm_release` + `depends_on` na release que traz os
CRDs:

- `terraform/cluster/charts/nodepools`: HCloudNodeClass + NodePool.
- `terraform/cluster/charts/cluster-issuers`: ClusterIssuers staging/prod.

Os valores (IDs, zonas, e-mail, Secret refs) são passados pelo Terraform. IDs numéricos usam `| int64` no
template, porque o Helm lê números como float64 e renderizaria `1.2e+07`.

## Alternativas consideradas

- **Dois applies / `-target`:** frágil e manual.
- **Provider `kubectl` (gavinbunney/alekc):** aplica YAML sem schema no plan, mas é mais um provider de terceiros.
- **Root separado só para CRs:** ainda mais um state e mais uma etapa.

## Consequências

- Um único `terraform apply` no `cluster` resolve tudo.
- Os charts podem ser verificados offline (`helm lint --strict`, `helm template`), inclusive no CI.
- O diff no plan é por valores da release, não por recurso Kubernetes.

## Atualizações
- **2026-10-27:** Toda mudança de template de um chart local exige aumentar o `version` do `Chart.yaml`: o provider
  Helm só compara values e versão do chart, e uma edição só no template não aparece no plan.
