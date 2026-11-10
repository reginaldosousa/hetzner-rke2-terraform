# 0035. Login do Tsuru pelo Pocket ID

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/tsuru.tf terraform/identity`

## Contexto

O kubectl, a VPN, o Grafana e o Harbor já usam o Pocket ID ([ADR 0023](0023-oidc-pocket-id.md)). O Tsuru tem um
esquema `oidc`: o CLI faz o fluxo authorization code com PKCE e um callback em `localhost`, e manda o **access
token** à API, que o valida pelas chaves públicas (JWKS) do provedor. Com `groups-in-claims`, os grupos do token
viram grupos do usuário no Tsuru, e papéis podem ser dados a grupos.

Duas limitações moldam a decisão:

- `auth:user-registration` liga duas coisas ao mesmo tempo: a criação do usuário no primeiro login OIDC e o
  `POST /users` anônimo. Com o esquema `native` disponível (sozinho ou no `multi`), qualquer um que alcance a API
  (pela VPN, ou um pod do cluster) cria um usuário com senha.
- O esquema `oidc` verifica assinatura e validade, mas não a audiência. O `valid-claims` compara cada claim como
  string. Os access tokens do Pocket ID (fosite) não têm `azp` nem `client_id`, e o `aud` é uma lista, que nunca é
  igual a uma string.

## Decisão

- **`auth.scheme: oidc`**, sem `native` e sem `multi`. Com o OIDC, o `POST /users` responde 501. O
  `user-registration` fica ligado e só serve para o primeiro login de alguém do Pocket ID criar o próprio usuário.
- **Client público `tsuru` no Pocket ID** (root `identity`), callback fixo `http://localhost:38080/`
  (`callback-port: 38080`), escopos `openid email profile groups`. Podem entrar os grupos `k8s-admins` e
  `tsuru-devs` (novo).
- **Bootstrap sem senha:** o primeiro admin faz `tsuru login` pelo Pocket ID, e alguém com kubectl roda
  `tsurud root user create <email>` dentro do pod da API. Com o usuário já existente, o comando só dá o papel
  `AllowAll`, sem senha.
- **Papéis por grupo:** `k8s-admins` recebe `AllowAll`. `tsuru-devs` recebe um papel de deploy no time que o
  administrador criar. As atribuições são feitas pelo CLI e ficam no MongoDB.
- **`valid-claims` fixa o `iss`** no URL do Pocket ID. A variável `tsuru_oidc_valid_claims` aceita mais claims de
  string, para quando o Pocket ID passar a emitir um que identifique o client.

## Alternativas consideradas

- **`multi` com `native` para break-glass:** reabre o cadastro anônimo pelo `POST /users`. Desligar o
  `user-registration` fecharia isso, mas também desligaria a criação de usuários pelo OIDC, e cada pessoa teria de
  ser cadastrada à mão.
- **Só `native`:** mais uma senha por pessoa, sem passkey e sem revogação central.
- **Esquema `oauth` do Tsuru:** é o OAuth2 genérico antigo, que lê o usuário de um `info-url`, sem JWKS nem grupos.

## Consequências

- **Sem checagem de audiência**, a API aceita um access token do Pocket ID emitido para outro client (Grafana,
  Harbor) se ele tiver email. O efeito é limitado: um usuário só obtém tokens dele mesmo, o usuário criado nasce
  sem papel nenhum no Tsuru e não pode fazer nada até um admin dar um papel ao grupo dele.
- **Sem break-glass de login:** se o Pocket ID cair, ninguém entra no Tsuru. Os apps continuam no ar, e quem tem o
  kubeconfig de admin opera o cluster direto.
- Desativar alguém é no Pocket ID (`disabled = true` no root `identity`). Tokens já emitidos valem até expirar.
- O primeiro `tsuru login` precisa confirmar que o access token do Pocket ID traz `email` e `groups`. Se não trouxer,
  o login falha com "email claim is missing", e a correção é o mapeamento de claims do Pocket ID.
