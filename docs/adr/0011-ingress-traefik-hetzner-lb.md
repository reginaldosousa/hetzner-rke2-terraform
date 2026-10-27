# 0011. Ingress com o Traefik do RKE2 atrás de um Hetzner LB criado pelo CCM

- **Status:** Aceito
- **Commits:** `199d880`, `c1f051f`, `d6bb72b`

## Contexto

Os workers não têm IP público, então é preciso um ponto de entrada público para HTTP/HTTPS. As aplicações
precisam do IP real do cliente. O RKE2 já traz o Traefik instalado.

## Decisão

Um `HelmChartConfig` (`terraform/cluster/ingress.tf`) reconfigura o `rke2-traefik`:

- Service `type: LoadBalancer`, que faz o hcloud CCM criar um `lb11` (`<cluster>-ingress`) falando com os nós
  pelo IP privado (`use-private-ip`).
- `disable-private-ingress`: o IP privado do LB não entra no status do Service, para o external-dns não publicar
  um `10.x` no DNS público.
- **PROXY protocol** no LB, aceito pelo Traefik **apenas** de `network_cidr`.
- `externalTrafficPolicy: Local`: o LB só usa nós com um pod do Traefik. Com `Cluster`, o salto pelo kube-proxy
  fazia SNAT, a origem saía da faixa confiável e 3 de 4 requisições perdiam o IP real.
- `publishedService` copia o IP do LB para o status dos Ingress, que é o que o external-dns lê.
- Redirect 308 de `web` para `websecure` no entrypoint.

## Alternativas consideradas

- **ingress-nginx:** mais um chart para manter, e a configuração do RKE2 já cobre o Traefik.
- **LB no Terraform (`hcloud_load_balancer`):** teria o ciclo de vida no Terraform, mas precisaria registrar os
  targets à mão, que mudam o tempo todo com o Karpenter. O CCM já faz isso.
- **hostNetwork/NodePort em nós com IP público:** contraria o [0003](0003-private-network-wireguard-gateway.md).
- **Cloudflare Tunnel:** dispensa o LB, mas coloca todo o tráfego atrás de um agente e de um provedor específico.

## Consequências

- Custo de um `lb11` (~€7,89/mês).
- **O LB não está no Terraform:** antes de destruir o cluster, remova o Service `rke2-traefik` (ou o LB no
  console), senão ele continua cobrando.
- As aplicações recebem o IP real (`X-Real-Ip`/`X-Forwarded-For`).
- Hosts sem certificado recebem o certificado autoassinado padrão do Traefik.
