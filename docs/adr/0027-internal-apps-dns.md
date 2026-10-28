# 0027. Aplicações internas pela VPN: zona `.internal`, DNS no gateway e LB só privado

- **Status:** Aceito
- **Commits:** `bfb1300`, `2953dc1`, `da33c4c`, `06612f8`

## Contexto

Ferramentas como o Grafana não devem ficar na internet, mas acessá-las por `kubectl port-forward` não escala
para várias aplicações nem para quem não tem kubeconfig. Queremos nomes como `grafana.<domínio>`, que só
resolvem e só respondem pela VPN (tailnet ou WireGuard), e sem registrar um domínio para isso.

Um domínio não registrado num TLD público (ex.: `devcomm.services`) pode ser registrado por outra pessoa a
qualquer momento. A partir daí, fora da VPN, bookmarks, cookies e senhas salvas vão para o servidor dela, e
nenhuma CA pública emite certificado para nós nesse nome. A ICANN reservou `.internal` para uso privado (2024),
então esse TLD nunca vai ser delegado.

## Decisão

- **Zona `internal_domain`** (variável do `infra`, padrão `<cluster_name>.internal`; a validação exige o
  sufixo `.internal`). Este cluster usa `devcomm.internal`. O `cluster` lê a zona pelo remote state.
- **DNS no gateway:** um `dnsmasq` (binário do `dnsmasq-base`, unit própria `internal-dns.service`) escuta só
  em `10.0.1.2:53` e responde **qualquer nome da zona** com o IP do LB interno. Ele não tem upstream, então não
  resolve nenhum outro nome. O nftables só libera a porta 53 vinda das interfaces da VPN. O Headscale entrega a
  zona como **split DNS** (`dns.nameservers.split`): os clientes da tailnet mandam só essa zona para o gateway e
  o resto do DNS continua o deles.
- **LB de ingress só privado:** um segundo Service do Traefik (`service.additionalServices.internal`) faz o CCM
  criar `<cluster>-ingress-internal` (`lb11`) com `disable-public-network` e IP fixo `private-ipv4`
  (`cidrhost(subnet_cidr, -2)`, hoje `10.0.1.254`, no topo da subnet porque os workers pegam os IPs livres mais
  baixos). PROXY protocol como no LB público.
- **Entrypoints separados:** o LB interno só leva `internal` (443 → 8444) e `internal-web` (80 → 8001, redirect
  para HTTPS). `web`/`websecure` são `asDefault`, então um router que não escolhe entrypoint fica só no LB
  público. Uma aplicação interna se declara com `traefik.ingress.kubernetes.io/router.entrypoints: internal`.
- **Política de admissão** (`ValidatingAdmissionPolicy`, `terraform/cluster/internal-apps.tf`): Ingress ou
  IngressRoute com host na zona interna é recusado se não estiver **apenas** nos entrypoints internos. Sem isso,
  quem mandasse `Host: grafana.devcomm.internal` para o IP do LB público chegaria na aplicação.
- **Firewall do gateway:** da VPN para o LB interno passam só `tcp/80` e `tcp/443`. A policy do Headscale
  libera o mesmo (e o DNS) para `autogroup:member`.
- **TLS com CA privada:** o cert-manager gera uma CA raiz (`ClusterIssuer internal-ca`, ECDSA P-256, 10 anos,
  `rotationPolicy: Never`) com **name constraint** crítico na zona interna: mesmo vazada, a chave não assina
  certificado para outro nome, e confiar nela num laptop não abre nada além da zona. Os certificados das
  aplicações são pedidos pela anotação `cert-manager.io/cluster-issuer: internal-ca`.
- **Primeira aplicação:** Grafana em `https://grafana.devcomm.internal`.

## Alternativas consideradas

- **Domínio público não registrado (`devcomm.services`):** risco de alguém registrar o nome, descrito acima.
- **Subdomínio da zona que já temos (`*.internal.devcomm.com.br`):** daria certificados Let's Encrypt sem CA
  privada, mas os nomes ficam no DNS público e no Certificate Transparency. Fica como opção se instalar a CA nos
  dispositivos virar problema.
- **Registros públicos apontando para IPs privados:** vaza nomes e endereços, e roteadores com proteção contra
  DNS rebinding descartam a resposta.
- **Entrypoint interno no LB público, protegido por allowlist de IP:** economiza o `lb11`, mas a porta interna
  ficaria exposta na internet e a isolação dependeria só do middleware.
- **`extra_records` do Headscale:** sem wildcard (um registro por aplicação no Terraform) e não atende o
  WireGuard.
- **Pacote `dnsmasq` completo:** o serviço do pacote se registra no resolvconf e escuta além do IP privado.

## Consequências

- US$ 7,89/mês a mais pelo segundo `lb11` ([custos](../costs.md)). Como o LB público, ele não está no
  Terraform: antes de destruir o cluster, remova o Service `rke2-traefik-internal`.
- Cada dispositivo precisa confiar na CA (`docs/operations.md`). Recriar o cluster sem restaurar o Secret
  `cert-manager/internal-ca` gera outra raiz, que precisa ser instalada de novo.
- Clientes da tailnet precisam aceitar DNS (`--accept-dns`, o padrão dos apps). Clientes WireGuard não recebem
  split DNS: configuram o resolver da zona à mão (`/etc/resolver/<zona>` no macOS).
- Uma aplicação interna nova é só um Ingress com host na zona, a anotação de entrypoint e a de issuer: DNS e
  certificado não pedem passo manual.
- A política cobre Ingress e IngressRoute. Outro tipo de rota (Gateway API, IngressRouteTCP) precisaria entrar
  nela.
