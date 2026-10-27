# 0012. DNS e TLS: external-dns + cert-manager com DNS-01 no Cloudflare

- **Status:** Aceito
- **Commits:** `d76c189`, `f043dc4`, `765e667`

## Contexto

As zonas DNS (ex.: `devcomm.com.br`) estão no Cloudflare. Criar registros e certificados à mão para cada
aplicação não escala e diverge do estado do cluster.

## Decisão

- **external-dns** (chart `kubernetes-sigs`, fontes `ingress` e `service`) publica A/AAAA no Cloudflare apontando
  para o IP do LB de ingress. `policy: sync` com `registry: txt` e `txtOwnerId = cluster_name` faz ele apagar
  apenas o que criou. `domainFilters = external_dns_domains` é obrigatório: uma lista vazia é rejeitada pela
  validação.
- **cert-manager** (chart jetstack, CRDs incluídos) com dois ClusterIssuers, `letsencrypt-staging` e
  `letsencrypt-prod`, resolvendo **DNS-01** no Cloudflare e restritos às mesmas zonas.
  - A propagação é checada em `1.1.1.1`/`8.8.8.8`, não no CoreDNS, para um NXDOMAIN em cache não travar a
    emissão.
- Um único token Cloudflare (Zone:Read + DNS:Edit apenas nessas zonas) alimenta os dois componentes, em Secrets
  separados por namespace.
- Para pedir um certificado: anotação `cert-manager.io/cluster-issuer` + bloco `tls` no Ingress.

## Alternativas consideradas

- **HTTP-01:** exige a porta 80 servindo o desafio, o que conflita com o redirect 308, e não emite wildcard.
- **DNS manual / Terraform `cloudflare_record`:** os registros ficariam desacoplados do ciclo de vida dos Ingress.
- **Cloudflare proxy + Origin CA:** possível via anotação `cloudflare-proxied`, mas amarra o TLS à Cloudflare.
  Fica como opção por host.
- **Traefik ACME embutido:** guarda os certificados em arquivo/PVC por réplica, sem o modelo declarativo
  `Certificate`.

## Consequências

- Um Ingress novo com host e `tls` ganha DNS e certificado válidos sem passo manual.
- Apagar um Ingress apaga os registros DNS dele.
- O token Cloudflare fica no state do `cluster` e em dois Secrets.
- Testar primeiro com staging evita os rate limits de produção do Let's Encrypt.

## Atualizações
- **2026-10-27:** O token Cloudflare não é mais criado à mão: `terraform/cluster/dns-token.tf` cria um token de
  conta com Zone Read + DNS Write só nas zonas de `external_dns_domains`, usando um token de provisionamento que
  nunca entra no cluster ([0019](0019-etcd-snapshots-r2.md)).
