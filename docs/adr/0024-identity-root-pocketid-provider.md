# 0024. Terceiro root `identity`, com o provider comunitário do Pocket ID

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/identity`

## Contexto

Grupos, clients OIDC e usuários do Pocket ID ([ADR 0023](0023-oidc-pocket-id.md)) eram criados à mão na UI. Na
primeira vez, o grupo saiu com o nome errado (`k8s-admin` em vez de `k8s-admins`) e vazio, e isso faria o login
no kubectl entrar sem permissão nenhuma. Gerenciar pela API exige uma API key, e ela só existe depois que o
primeiro admin é criado no `/setup`.

## Decisão

- **Root `terraform/identity`**, aplicado depois do `cluster`, com state em `identity/terraform.tfstate` no R2.
  Ele lê `oidc_issuer_url` do state do `infra` e fala com a API pública do Pocket ID, sem precisar de VPN.
- **Provider `Trozz/pocketid`**, fixado em versão exata (`2.4.2`). É comunitário e mantido por uma pessoa, mas
  tem licença MIT, releases assinadas com GPG e só fala com o `base_url` configurado (código da v2.4.2 revisado).
  Upgrade só depois de ler o diff.
- **Gerenciado:** o grupo `k8s-admins`, o client `kubectl` (público, PKCE, restrito ao grupo) e os usuários,
  com os grupos de cada um, a partir da variável `users`. O client e os usuários têm `prevent_destroy`: o ID do
  client é a audience do apiserver, e apagar um usuário apaga as passkeys dele.
- **API key** em `terraform/identity/terraform.tfvars`, com validade, fora do cluster.

## Alternativas consideradas

- **Recursos no root `cluster`:** a API key não existe no primeiro apply, o que travaria o bootstrap de um
  cluster novo.
- **Continuar pela UI:** sem revisão e sem histórico, e o erro de nome do grupo passaria despercebido.

## Consequências

- Ordem de apply: `infra` → `cluster` → setup do admin e criação da API key → `identity` → `oidc_client_id` no
  `infra` e `sync-masters.sh`.
- Quando a API key expira, o `identity` para de aplicar até que uma nova seja posta no tfvars.
- Passkeys continuam fora do Terraform: cada usuário cadastra a própria, por um link de acesso único.

## Atualizações
- **2026-11-10:** O projeto do provider passou para a organização do Pocket ID
  ([github.com/pocket-id/terraform-provider](https://github.com/pocket-id/terraform-provider)), e o repositório
  original do Trozz ficou sem releases. O registry ainda publica o provider como `trozz/pocketid`, mas aponta os
  downloads para o repositório antigo, e `terraform init` falha com 404. Os binários da release oficial são os
  mesmos: os hashes do `.terraform.lock.hcl` batem com o `SHA256SUMS` da v2.4.2. O endereço `trozz/pocketid` e o
  lock file continuam, e `scripts/pocketid-provider-mirror.sh` baixa o zip da release oficial para um filesystem
  mirror (`TF_CLI_CONFIG_FILE`). O Terraform recusa um zip que não bata com o lock file (testado com um binário
  alterado). O CI usa o mesmo script. Quando o registry voltar a apontar para o repositório oficial, o script
  pode sair.
