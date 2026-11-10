# 0035. Login do Tsuru pelo Pocket ID

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/tsuru.tf terraform/identity`

## Contexto

O kubectl, a VPN, o Grafana e o Harbor já usam o Pocket ID ([ADR 0023](0023-oidc-pocket-id.md)). O Tsuru tem um
esquema `oidc`: o CLI faz o fluxo authorization code com um callback em `localhost`, e a API valida o JWT pelas
chaves públicas (JWKS) do provedor. Com `groups-in-claims`, os grupos do token viram grupos do usuário no Tsuru, e
papéis podem ser dados a grupos. Também há um esquema `multi`, que combina `oidc` com o `native` (usuário e senha no
banco do Tsuru).

O esquema `oidc` do Tsuru verifica a assinatura e a validade do token, mas não a audiência (`aud`). Seu
`valid-claims` compara cada claim por igualdade simples, o que não funciona com `aud` em forma de lista.

## Decisão

- **`auth.scheme: multi`**, esquemas `oidc` (padrão) e `native`. O `native` existe só para o usuário root de
  break-glass, criado no bootstrap com `tsurud root user create`.
- **Client público `tsuru` no Pocket ID** (root `identity`), callback fixo `http://localhost:38080/`
  (`callback-port: 38080`), escopos `openid email profile groups`. Podem entrar os grupos `k8s-admins` e
  `tsuru-devs` (novo).
- **Usuários criados no primeiro login** (`user-registration`), identificados pelo email do token.
- **Papéis por grupo:** `k8s-admins` recebe `AllowAll`. `tsuru-devs` recebe um papel de deploy no time que o
  administrador criar. As atribuições são feitas pelo CLI no bootstrap e ficam no MongoDB.
- **`valid-claims` fixa o `iss`** no URL do Pocket ID.

## Alternativas consideradas

- **Só `native`:** mais uma senha por pessoa, sem passkey e sem revogação central.
- **Esquema `oauth` do Tsuru:** é o OAuth2 genérico antigo, que lê o usuário de um `info-url`, sem JWKS nem grupos.

## Consequências

- **Sem checagem de audiência**, a API aceita qualquer token assinado pelo Pocket ID que tenha email, inclusive um
  emitido para outro client (Grafana, kubectl). O efeito é limitado: um usuário só obtém tokens dele mesmo, e sem um
  papel no Tsuru o usuário criado não pode nada. Quando confirmarmos que o token que o CLI envia traz `aud` (ou
  `azp`) como string, entra em `valid-claims` (`tsuru_oidc_audience_claim`).
- Desativar alguém é no Pocket ID (`disabled = true` no root `identity`). Tokens já emitidos valem até expirar.
- Se o Pocket ID cair, só o root `native` entra no Tsuru.
- O teste do primeiro `tsuru login` precisa confirmar duas coisas: que o CLI manda PKCE (o client público do Pocket
  ID exige) e qual token ele envia à API.
