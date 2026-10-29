# 0023. Login OIDC no kubectl com Pocket ID

- **Status:** Aceito
- **Commits:** `48852cd`, `ee78a3d`, `9ceee1f`, `70269b6`, `90792b0`

## Contexto

O acesso ao cluster é o kubeconfig admin do RKE2: um certificado `cluster-admin` sem identidade, sem expiração
curta e sem revogação individual. Quem tem o arquivo e a VPN tem tudo. O plano é dar identidade também à VPN
(Headscale, numa ADR futura), com o mesmo provedor.

## Decisão

- **Pocket ID** (v2, imagem distroless) como provedor OIDC, rodando no cluster (`terraform/cluster/pocket-id.tf`)
  em `oidc_issuer_url` (`https://auth.devcomm.com.br`). O login é só por passkey, sem senha.
- **Público**, atrás do Traefik com certificado Let's Encrypt: o login da VPN vai acontecer antes de existir
  túnel. O apiserver busca o JWKS pela internet, saindo pelo NAT do gateway.
- **SQLite num Hetzner Volume**, uma réplica, `Recreate`. A chave de criptografia é gerada pelo Terraform. O
  namespace é `restricted`. O Velero copia o volume todo dia ([ADR 0022](0022-velero-r2.md)).
- **kube-apiserver com `AuthenticationConfiguration` (`apiserver.config.k8s.io/v1`)**, entregue como drop-in nos
  masters ([ADR 0018](0018-pod-security-baseline.md)) e ligado só quando `oidc_client_id` existe. O RKE2 monta
  o arquivo no static pod sozinho, como faz com os outros argumentos de arquivo.
- **Identidade:** username = `oidc:<sub>`, porque email e username são editáveis no Pocket ID. Grupos =
  `oidc:<grupo>`. O RBAC só usa grupos: `oidc:k8s-admins` → `cluster-admin`.
- **Cliente:** `kubelogin` (`kubectl oidc-login`) com client público e PKCE.
- **Break-glass:** o kubeconfig admin do RKE2 continua existindo e é o que o `terraform/cluster` usa.

## Alternativas consideradas

- **Keycloak / Authentik:** mais recursos, mas bem mais pesados (Java ou Python, Postgres, Redis) para um
  cluster de 3 masters `cax11`.
- **IdP SaaS (Google, Entra):** sem nada para operar, mas a identidade sai do controle do projeto.
- **Pocket ID no gateway:** mantém o IdP fora do cluster, mas aumenta a superfície do host mais sensível.
- **Flags `--oidc-*` antigas:** um único issuer só. A configuração estruturada aceita vários (a VPN pode ter o
  seu) e regras em CEL.
- **Só pela VPN:** menos superfície, mas não serviria para autenticar a própria VPN.

## Consequências

- Se o Pocket ID cair (cluster fora do ar, volume perdido), o login OIDC para. O acesso volta pelo kubeconfig
  admin.
- A página `/setup` do Pocket ID fica aberta até a criação do primeiro admin. Por isso
  `pocket_id_allowed_cidrs` (obrigatória) limita o Ingress ao IP do operador por um middleware `ipAllowList` do
  Traefik, até o setup terminar. Não dá para fazer o setup por port-forward: a passkey fica presa ao host público.
- `oidc_issuer_url` precisa bater exatamente com o `iss` do token. Mudar o host exige um apply do `infra`, um
  `sync-masters.sh` e kubeconfigs novos.
- Perder a chave de criptografia (state) deixa o banco ilegível.
- RBAC por usuário não funciona por nome; tudo passa por grupos no Pocket ID.

## Atualizações
- **2026-10-29:** O Grafana é o terceiro client OIDC (`pocketid_client.grafana`, confidencial com PKCE), depois
  do `kubectl` e do Headscale. Entram `k8s-admins` (papel Admin) e `vpn` (Viewer); qualquer outro é recusado, e o
  papel é sincronizado a cada login. O ID e o secret vão do `identity` para a variável `grafana_oidc` do
  `cluster` por um `grafana-oidc.auto.tfvars.json` ignorado pelo git, e o secret chega ao Grafana por um Secret.
  O usuário `admin` continua como break-glass em `/login?disableAutoLogin=true`.
