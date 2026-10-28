# Post de divulgação no LinkedIn

Texto puro, para colar direto no LinkedIn (ele não renderiza Markdown; o bloco abaixo preserva as quebras de
linha). Troque `[link PT]` e `[link EN]` pelos links dos artigos
([PT-BR](kubernetes-production-ready-baixo-custo.md), [EN](kubernetes-production-ready-low-cost.en.md)). Cerca
de 2.300 caracteres, dentro do limite de 3.000.

```text
(English version below 👇)

Quanto custa um Kubernetes que eu teria coragem de colocar em produção?

Fiz a conta: cerca de US$ 61 por mês.

Montei um cluster RKE2 na Hetzner Cloud, todo em Terraform, com:

→ control plane em alta disponibilidade
→ workers que escalam sozinhos com Karpenter
→ nenhum nó exposto na internet
→ TLS automático no ingress
→ Grafana e ferramentas internas só pela VPN, com certificado válido
→ backups fora do provedor e alertas que funcionam até com o gateway fora do ar
→ login por passkey no kubectl e na VPN

O mais interessante não foi o preço, foram as pegadinhas. Algumas que conto no artigo:

• 3 de 4 requisições perdiam o IP real do cliente, por causa de uma única linha de configuração
• o metadata service entrega o user_data do servidor a qualquer pod no nó
• o load balancer pago do control plane não acrescentava disponibilidade nenhuma
• se o gateway cair, nenhum alerta sai, a não ser que você monte um dead man's switch

Custo baixo e produção não são opostos, desde que cada decisão fique registrada.

Artigo completo: [link PT]

Já rodou Kubernetes fora das nuvens grandes? Qual pegadinha te custou mais tempo?

—

🇺🇸 English version

How much does a Kubernetes cluster I'd actually trust with production cost?

I did the math: about $61 a month.

I built an RKE2 cluster on Hetzner Cloud, entirely in Terraform, with:

→ a highly available control plane
→ workers that scale on their own with Karpenter
→ no node exposed to the internet
→ automatic TLS on ingress
→ Grafana and internal tools reachable only over the VPN, with valid certificates
→ off-provider backups and alerts that work even when the gateway is down
→ passkey login for kubectl and the VPN

The price wasn't the most interesting part. The pitfalls were. A few I cover in the article:

• 3 out of 4 requests lost the client's real IP, because of a single line of configuration
• the metadata service hands the server's user_data to any pod on the node
• the paid control plane load balancer added no availability at all
• if the gateway goes down, no alert gets out, unless you set up a dead man's switch

Low cost and production are not opposites, as long as every decision is written down.

Full article: [link EN]

Have you run Kubernetes outside the big clouds? Which pitfall cost you the most time?

#Kubernetes #DevOps #Terraform #CloudComputing #Hetzner
```
