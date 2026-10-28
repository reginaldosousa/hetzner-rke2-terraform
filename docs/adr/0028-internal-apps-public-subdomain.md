# 0028. Aplicações internas num subdomínio público com wildcard do Let's Encrypt

- **Status:** Aceito (substitui a zona `.internal` e a CA privada do [0027](0027-internal-apps-dns.md))
- **Commits:** `5eb0ae1`, `ee0df47`, `b4ad991`, `8b9f484`

## Contexto

O [ADR 0027](0027-internal-apps-dns.md) pôs as aplicações internas em `devcomm.internal`, com certificados de uma
CA privada. Nenhuma CA pública emite para `.internal`, então cada dispositivo (e o Firefox, à parte) precisava
instalar a raiz. Queremos certificados que os navegadores aceitam sem passo nenhum no dispositivo.

## Decisão

- **Zona `int.devcomm.com.br`**, subdomínio de uma zona que já está no Cloudflare. `internal_domain` passa a ser
  obrigatório no `infra`, e o `cluster` exige que ele esteja sob uma das `external_dns_domains`.
- **Nada da zona no DNS público.** O dnsmasq do gateway e o split DNS do Headscale continuam como no 0027: fora
  da VPN os nomes dão NXDOMAIN. O external-dns ganha `excludeDomains` com a zona, porque o status de todo Ingress
  traz o IP do LB público, e sem a exclusão ele publicaria o host interno apontando para lá.
- **Um wildcard `*.int.devcomm.com.br`** do `letsencrypt-prod`, por DNS-01 (só um TXT temporário no Cloudflare),
  no chart local `charts/internal-tls`. O Secret fica no `kube-system` e entra no **TLSStore `default`** do
  Traefik, que escolhe o certificado pelo SNI. Uma aplicação interna só declara
  `traefik.ingress.kubernetes.io/router.tls: "true"`, sem bloco `tls` nem issuer.
- **A CA privada sai.** O LB só privado, os entrypoints separados, o firewall do gateway e a política de
  admissão continuam iguais.

## Alternativas consideradas

- **Manter `.internal` com a CA privada:** funciona, mas exige instalar a raiz em cada dispositivo.
- **Um certificado por aplicação:** cada nome iria para os logs de Certificate Transparency. O wildcard mostra
  só que a zona existe.
- **TLSStore com `defaultCertificate`:** o Traefik serviria o wildcard também a hosts desconhecidos no LB
  público. Em `certificates`, ele só é usado quando o SNI casa.
- **Certificados HTTPS do Tailscale:** só existem nos domínios `ts.net` com o servidor de coordenação da
  Tailscale, não com o Headscale.

## Consequências

- Os navegadores confiam nos certificados sem instalar nada. Não há mais chave de CA no cluster.
- O nome da zona fica público pelos logs de CT (`*.int.devcomm.com.br`), e um lookup público dá NXDOMAIN. Os
  nomes das aplicações e os endereços não ficam públicos.
- O wildcard cobre um nível só: `grafana.int.devcomm.com.br` sim, `a.b.int.devcomm.com.br` não.
- A renovação depende do token DNS do Cloudflare e do Let's Encrypt, como os certificados públicos. Se ela falhar,
  o Certificate fica `READY=False` e sobram até 30 dias antes de o certificado vencer.
- O mesmo Secret serve todas as aplicações internas: ele só existe no `kube-system`, e nenhum namespace de
  aplicação o recebe.
