# 0006. Dois roots Terraform: `infra` e `cluster`

- **Status:** Aceito
- **Commits:** `9f532f2`, `04881d6`

## Contexto

Os providers `kubernetes`/`helm` precisam de um cluster acessível já na fase de plan. Esse cluster só existe
depois que os servidores sobem, e só é acessível pela VPN. Num root único, o primeiro `apply` falharia, e
qualquer `plan` sem VPN quebraria até para mudanças que só tocam a Hetzner.

## Decisão

- `terraform/infra` fala **só** com a API da Hetzner: rede, gateway, masters, chaves, tokens e userData dos
  workers. Funciona sem VPN (exceto o `gateway_sync`, ver [0009](0009-gateway-config-sync.md)).
- `terraform/cluster` fala **só** com o Kubernetes, via `../../kubeconfig` pela VPN. Ele lê os outputs do
  `infra` por `terraform_remote_state` (R2, `infra/terraform.tfstate`).
- A ordem de aplicação é sempre `infra` → `cluster`.

## Alternativas consideradas

- **Root único com `-target`:** frágil, propenso a erro e desencorajado pela própria HashiCorp.
- **Terragrunt / Terraform Stacks:** resolvem dependências entre stacks, mas acrescentam ferramenta e conceitos
  para apenas duas camadas.
- **Tudo no cloud-init (manifests RKE2):** colocaria segredos (token da Hetzner, Cloudflare) no user_data, o que
  é inaceitável ([0008](0008-secrets-out-of-user-data.md)).

## Consequências

- Os outputs do `infra` são a interface entre os roots. Renomear ou remover um output, ou mudar o backend do
  `infra`, quebra o `cluster`.
- Mudanças só de infra não exigem VPN para o plan.
- Há dois states para fazer backup e dois `apply` no bootstrap.
