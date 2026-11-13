# 0035. Login do Tsuru pelo Pocket ID

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/tsuru.tf terraform/identity`

## Contexto

O kubectl, a VPN, o Grafana e o Harbor já usam o Pocket ID ([ADR 0023](0023-oidc-pocket-id.md)). O Tsuru tem um
esquema `oidc`: o CLI faz o fluxo authorization code com PKCE e um callback em `localhost`, e manda o **access
token** à API, que o valida pelas chaves públicas (JWKS) do provedor. Com `groups-in-claims`, os grupos do token
viram grupos do usuário no Tsuru, e papéis podem ser dados a grupos.

Quatro limitações moldam a decisão (as duas últimas descobertas no primeiro login, em 2026-11-11):

- `auth:user-registration` liga duas coisas ao mesmo tempo: a criação do usuário no primeiro login OIDC e o
  `POST /users` anônimo. Com o esquema `native` disponível (sozinho ou no `multi`), qualquer um que alcance a API
  (pela VPN, ou um pod do cluster) cria um usuário com senha.
- O esquema `oidc` verifica assinatura e validade, mas não a audiência. O `valid-claims` compara cada claim como
  string, e o `aud` dos tokens do Pocket ID é uma lista, que nunca é igual a uma string.
- O CLI oficial (até a v1.38.1) manda o pedido de autorização com `state` vazio, e o Pocket ID (fosite) recusa:
  `invalid_state ... must be at least 8 characters`.
- O Pocket ID até a v2.19.x só põe `email` e `groups` no **ID token**. O access token, que o CLI manda à API, tem
  só `sub`, `client_id` e os escopos, e o Tsuru responde 401 sem email. A política de mapeamento de claims, que leva
  claims ao access token, só existe no `main` do Pocket ID.

## Decisão

- **`auth.scheme: oidc`**, sem `native` e sem `multi`. Com o OIDC, o `POST /users` responde 501. O
  `user-registration` fica ligado e só serve para o primeiro login de alguém do Pocket ID criar o próprio usuário.
- **CLI com dois patches** (`github.com/tsuru/tsuru-client`, branch `fix/oidc-state` no checkout do operador):
  um `state` aleatório por login, conferido no callback, e, com `TSURU_OIDC_BEARER=id_token`, o **ID token** como
  bearer, também depois de cada refresh. Sem a variável, o CLI se comporta como o oficial. Os dois servem para
  upstream.
- **Client público `tsuru` no Pocket ID** (root `identity`), callback fixo `http://localhost:38080`, com e sem a
  barra final, porque o Pocket ID compara o callback exatamente (`callback-port: 38080`), escopos
  `openid email profile groups`. Podem entrar os grupos `k8s-admins` e
  `tsuru-devs` (novo).
- **Bootstrap sem senha:** o primeiro admin faz `tsuru login` pelo Pocket ID, e alguém com kubectl roda
  `tsurud root user create <email>` dentro do pod da API. Com o usuário já existente, o comando só dá o papel
  `AllowAll`, sem senha.
- **Papéis por grupo:** `k8s-admins` recebe `AllowAll`. `tsuru-devs` recebe um papel de deploy no time que o
  administrador criar. As atribuições são feitas pelo CLI e ficam no MongoDB.
- **`valid-claims` fixa o `iss`** no URL do Pocket ID. A variável `tsuru_oidc_valid_claims` aceita mais claims de
  string. O access token traz `client_id` como string; quando o Pocket ID lançar o mapeamento de claims, o caminho é
  voltar ao access token com `email` e `groups` mapeados e exigir `client_id = <client tsuru>`.

## Alternativas consideradas

- **`multi` com `native` para break-glass:** reabre o cadastro anônimo pelo `POST /users`. Desligar o
  `user-registration` fecharia isso, mas também desligaria a criação de usuários pelo OIDC, e cada pessoa teria de
  ser cadastrada à mão.
- **Só `native`:** mais uma senha por pessoa, sem passkey e sem revogação central.
- **Esquema `oauth` do Tsuru:** é o OAuth2 genérico antigo, que lê o usuário de um `info-url`, sem JWKS nem grupos.
- **Esperar o mapeamento de claims do Pocket ID:** o caminho mais limpo, mas ninguém entraria no Tsuru até a release.

## Consequências

- **Sem checagem de audiência**, a API aceita um ID token do Pocket ID emitido para outro client (Grafana, Harbor),
  que também tem email. O efeito é limitado: um usuário só obtém tokens dele mesmo, o usuário criado nasce
  sem papel nenhum no Tsuru e não pode fazer nada até um admin dar um papel ao grupo dele.
- **Sem break-glass de login:** se o Pocket ID cair, ninguém entra no Tsuru. Os apps continuam no ar, e quem tem o
  kubeconfig de admin opera o cluster direto.
- Desativar alguém é no Pocket ID (`disabled = true` no root `identity`). Tokens já emitidos valem até expirar.
- **Todo operador usa o CLI com patch** e `TSURU_OIDC_BEARER=id_token` até os patches entrarem no CLI oficial e o
  Pocket ID lançar o mapeamento de claims. O CLI oficial não consegue entrar.
