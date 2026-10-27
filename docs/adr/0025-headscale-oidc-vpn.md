# 0025. VPN com login OIDC: Headscale no gateway

- **Status:** Aceito
- **Commits:** `f80ec35`, `79c61f1`, `78782c9`, `96178ce`, `7af51ad`, `d56b892`, `2838e1e`, `43c6250`

## Contexto

A VPN é WireGuard com chaves estáticas ([ADR 0003](0003-private-network-wireguard-gateway.md)): cada cliente é
uma chave gerada pelo Terraform, sem identidade, sem expiração e sem relação com o Pocket ID, que já autentica
o kubectl ([ADR 0023](0023-oidc-pocket-id.md)). Dar ou tirar acesso exige um apply do `infra`.

## Decisão

- **Headscale** (servidor de controle compatível com Tailscale, v0.29.6) **no gateway**, não no cluster: a VPN
  é o caminho para consertar o cluster, então não pode depender dele para aceitar conexões. Clientes usam o
  app oficial do Tailscale com `--login-server https://vpn.devcomm.com.br`.
- **Login pelo Pocket ID** (client confidencial com PKCE, criado pelo `terraform/identity`). Entra quem está no
  grupo `vpn` (`allowed_groups`); o login vale 30 dias (`headscale_node_expiry`).
- **O gateway é o subnet router** da rede privada: entra na própria tailnet com uma pre-auth key com
  `tag:gateway`, e a policy aprova a rota sozinha (`autoApprovers`). Os grants dão à tailnet o mesmo acesso dos
  clientes WireGuard: SSH e apiserver na rede, nada entre dispositivos de usuários.
- **DERP embutido** (relay no próprio Headscale, STUN em `udp/3478`), sem os relays da Tailscale. TLS por ACME
  TLS-ALPN-01 na `tcp/443`. O registro A é criado pelo `terraform/cluster`.
- **tailscaled com `--netfilter-mode=off`**: o `nftables.conf` do gateway é dono de todas as regras (o `flush
  ruleset` dele apagaria as do tailscaled). O tráfego da tailnet para a rede sai com **SNAT** para o IP do
  gateway, porque a Hetzner recusa rota para `100.64.0.0/10` (`invalid_input`).
- **Instalação idempotente e fixada**: `.deb` do Headscale conferido por sha256, Tailscale do repositório apt
  assinado em versão exata. O mesmo script roda no cloud-init e no `sync-gateway.sh`, que valida a policy no
  Headscale em execução antes de ativar e recarrega com SIGHUP quando só a policy muda.
- **WireGuard estático continua** como break-glass, inclusive para os applies.

## Alternativas consideradas

- **Headscale no cluster:** TLS e DNS prontos e backup pelo Velero, mas a VPN cairia junto com o cluster.
- **NetBird:** mais componentes (management, signal, relay) do que cabe num `cax11` ao lado do resto.
- **Cloudflare Zero Trust (WARP):** tira a VPN da própria infraestrutura.
- **wg-portal com OIDC:** mantém o WireGuard, mas tirar alguém do IdP não invalida a chave que ele já gerou.
- **Relays DERP da Tailscale:** menos portas abertas, mas o tráfego de relay passaria por terceiros.
- **Rota hcloud para a tailnet (sem NAT):** recusada pela API da Hetzner.

## Consequências

- O gateway expõe mais três portas: `tcp/443`, `udp/3478` e `udp/41641` (caminho direto do tailscaled).
- Os nós veem o IP do gateway, não o do cliente, para conexões vindas da tailnet.
- O banco do Headscale (SQLite em `/var/lib/headscale`) se perde num rebuild do gateway: o gateway se registra
  de novo sozinho (`tailnet-join.service`) e os usuários refazem o `tailscale up`.
- Login novo depende do Pocket ID, que vive no cluster. Se ele cair, quem já está logado continua até a
  expiração, e o WireGuard estático resolve o resto.
- Tirar alguém do grupo `vpn` bloqueia novos logins; para cortar uma sessão ativa antes da expiração, use
  `headscale nodes expire` no gateway.
