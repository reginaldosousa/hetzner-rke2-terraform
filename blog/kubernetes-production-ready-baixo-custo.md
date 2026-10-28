# Kubernetes production-ready por ~US$ 61/mês: o que aprendi montando um cluster na Hetzner

*Control plane em alta disponibilidade, workers que escalam sozinhos, nenhum nó na internet e login por passkey,
tudo em Terraform e por menos do que o NAT gateway de muita nuvem grande.*

## Introdução

Quem já abriu a fatura de um EKS, GKE ou AKS conhece a sensação: antes de a primeira aplicação subir, o control
plane gerenciado, o NAT gateway e o load balancer já custam mais do que muito projeto inteiro. Para um time
pequeno, um produto começando ou um laboratório sério, esse piso de custo pesa.

Eu queria descobrir quanto custaria um cluster que eu realmente teria coragem de colocar em produção, sem abrir
mão do básico. Para mim, "production-ready" significa:

- control plane em alta disponibilidade;
- workers que escalam sozinhos;
- nenhum nó exposto na internet;
- ingress público com TLS automático;
- ferramentas internas, como o Grafana, acessíveis só pela VPN;
- backups fora do provedor, monitoramento e alertas;
- login com identidade no `kubectl` e na VPN, sem certificados compartilhados.

O resultado foi um cluster RKE2 na Hetzner Cloud, inteiro em Terraform, com custo fixo de **cerca de US$ 61 por
mês**. Neste artigo conto como ele é montado e, principalmente, as pegadinhas que custaram tempo, porque são elas
que separam "funciona" de "dá para colocar produção em cima". Todo o código está aberto no GitHub:
[github.com/reginaldosousa/hetzner-rke2-terraform](https://github.com/reginaldosousa/hetzner-rke2-terraform).

## Desenvolvimento

### A arquitetura em uma frase

Só um servidor tem IP público: o **gateway**. Masters e workers vivem apenas na rede privada da Hetzner. O gateway
faz NAT para a saída dos nós, recebe a VPN e serve de endpoint do control plane. Os usuários entram por um load
balancer criado pelo próprio Kubernetes.

![Arquitetura: gateway como único host público, masters e workers na rede privada, LBs de ingress público e interno, e R2](images/arquitetura.png)

Na prática, o tráfego segue quatro caminhos: usuários pelo load balancer público, ferramentas internas pela VPN,
o operador pela VPN até o apiserver, e a saída dos nós pelo NAT do gateway.

![Fluxos de tráfego: entrada de usuários pelo LB, ferramentas internas pela VPN, acesso do operador pela VPN e saída dos nós pelo NAT do gateway](images/fluxos.png)

### Quanto custa, de verdade

Preços da API da Hetzner em outubro de 2026, em dólar e sem IVA:

- **Gateway e 3 masters `cax11`** (ARM, 2 vCPU, 4 GB): US$ 27,96
- **IPv4 do gateway:** US$ 0,60
- **Load balancer público** (`lb11`): US$ 7,89
- **Load balancer interno** (`lb11`, só rede privada): US$ 7,89
- **2 workers mínimos `cax11`:** US$ 13,98
- **Volumes** (Prometheus, Alertmanager, Pocket ID): US$ 3,07
- **Total fixo: US$ 61,39 por mês**

Workers extras custam cerca de um centavo de dólar por hora e somem quando a carga cai. Cloudflare R2, DNS,
Let's Encrypt, Telegram e healthchecks.io cabem nos planos gratuitos.

O que mais derrubou o custo foi tirar o IP público de todos os nós, concentrar NAT, VPN e endpoint do control
plane num gateway só, trocar um load balancer privado por um HAProxy nesse gateway, usar ARM e deixar o
Karpenter consolidar os workers ociosos.

### A stack, em poucas linhas

- **Hetzner Cloud** para servidores, rede, load balancers e volumes: barata, com API completa e CCM, CSI e um
  provider de Karpenter.
- **RKE2** como distribuição: instala por cloud-init, traz etcd em HA e já vem com Canal, CoreDNS e Traefik.
- **Terraform** para tudo, em três camadas: infraestrutura, cluster e identidade.
- **Headscale (Tailscale)** como VPN do dia a dia, com **WireGuard** puro como acesso de emergência.
- **Karpenter** para os workers, **Traefik**, **external-dns** e **cert-manager** para o ingress, e
  **kube-prometheus-stack**, **Velero** e **kured** para operar.
- **Pocket ID** como provedor de identidade, com login só por passkey.

### Lição 1: nenhum nó na internet, mas cuidado com o egress

A Hetzner nem deixa colocar firewall em servidor sem IP público. E tudo bem: o isolamento vem justamente de não
existir interface pública.

A pegadinha é a saída para a internet. Um servidor só com rede privada não recebe rota padrão por DHCP, então
não consegue baixar nada. Por isso, o **primeiro** passo do cloud-init de cada nó grava uma rota para o roteador
da rede e espera o NAT do gateway responder. Só depois disso ele instala o RKE2.

### Lição 2: o gateway concentra tudo, então ele precisa ser descartável

VPN, NAT e endpoint do control plane no mesmo servidor economizam dinheiro, mas fazem dele um ponto único de
falha. Os nós que já estão no cluster continuam funcionando se ele cair. O que para é o acesso, a saída para a
internet e a entrada de nós novos.

Em vez de HA, escolhi tornar o gateway **descartável**:

- O IP público é reservado e sobrevive a uma recriação, então nenhum cliente VPN precisa mudar nada.
- A configuração nunca exige recriar o servidor. Um script envia os arquivos, **valida no próprio gateway**
  (`nft -c`, `haproxy -c`) e só então ativa, sem derrubar túneis.
- Esse envio roda em todo `terraform apply` e é **fail-closed**: se falhar, o apply falha. Revogar o acesso de
  alguém à VPN nunca fica pendente em silêncio.
- A chave SSH do gateway é fixada pelo Terraform. O script nunca confia no primeiro host que responder, porque
  ele envia a chave privada do WireGuard.
- As chaves do Headscale vêm do Terraform, e o banco dele é replicado continuamente para o R2 pelo Litestream.

No teste, recriar o gateway levou cerca de 3 minutos, e os clientes da VPN reconectaram sozinhos, sem novo login.
HA de verdade exigiria um segundo gateway e um token com escrita no projeto inteiro dentro do único host público.
Para este cluster, alguns minutos de recuperação valem mais.

### Lição 3: às vezes o load balancer pago não acrescenta nada

Quem usa o endpoint do control plane? O `kubectl`, que já passa pela VPN no gateway, e nós entrando no cluster,
que já dependem do gateway para baixar o RKE2. Agentes já registrados balanceiam sozinhos entre os masters.

Ou seja, o gateway já estava no caminho, e um load balancer pago não acrescentava disponibilidade. Um HAProxy no
gateway resolve, com dois detalhes: o health check precisa ser HTTPS (o `/readyz` responde 401, porque a
autenticação anônima está desligada) e os timeouts precisam ser longos, senão `kubectl logs -f` cai.

### Lição 4: o metadata service entrega seus segredos a qualquer pod

O metadata service da Hetzner entrega o user_data do servidor a qualquer processo no nó, **inclusive pods**.
Então:

- Os masters têm o token de server do RKE2. Os workers recebem só o `agent-token`, que não dá poder de admin.
- O token da API da Hetzner nunca vai para o user_data. Ele chega ao cluster como Secret, pelo Terraform.
- Uma política do Calico bloqueia o acesso dos pods ao metadata service, com uma exceção explícita para o driver
  de volumes.
- Pod Security em `baseline` no cluster inteiro. Quem precisa de privilégio ganha uma exceção visível no código.

### Lição 5: o Karpenter funciona bem, desde que você respeite o contrato

O provider comunitário da Hetzner criou e removeu workers sem drama, mas tem regras:

- O NodePool precisa fixar `capacity-type: on-demand`, porque a Hetzner não tem spot, e sem isso a consolidação
  quebra.
- O user_data dos workers precisa de um taint específico, de `cloud-provider-name: external` e de reservas de
  recurso iguais às da NodeClass.
- NodeClass e NodePool vão num chart Helm local, porque o Terraform não consegue planejar um recurso cujo CRD
  ainda não existe.

Um caso que me pegou: com pouca carga, o Karpenter encolheu o cluster para **um** worker, que concentrava o único
Traefik. A queda desse nó derrubaria todo o ingress. A solução foram pods placeholder de prioridade negativa, um
por localização, com anti-afinidade obrigatória por zona. Um topology spread não bastou: ele se deu por satisfeito
com dois nós na mesma localização.

### Lição 6: o IP real do cliente se perde num lugar inesperado

O Traefik vira um Service do tipo LoadBalancer, e o Kubernetes cria o load balancer na Hetzner. Nos testes,
**3 de 4 requisições chegavam sem o IP real do cliente**. O culpado era `externalTrafficPolicy: Cluster`: o
kube-proxy fazia NAT no salto entre nós, e o Traefik deixava de confiar no cabeçalho PROXY. Com `Local`, o load
balancer só manda tráfego para nós que têm Traefik, e o IP real chega às aplicações.

Com external-dns e cert-manager, um Ingress novo já ganha registro DNS e certificado válido sem passo manual.

### Lição 7: ferramentas internas só pela VPN, com certificado válido

O Grafana não deve ficar na internet, mas `kubectl port-forward` não escala para várias ferramentas nem para
quem não tem kubeconfig. Eu queria `https://grafana.<algo>` que só resolve e só responde pela VPN, sem registrar
domínio novo e sem aviso de certificado no navegador.

- **Nada de domínio inventado.** Um nome não registrado num TLD público pode ser comprado por outra pessoa, e aí
  bookmarks e cookies vão para o servidor dela. O `.internal` é reservado e seguro, mas nenhuma autoridade
  certificadora pública emite para ele. Fiquei com um subdomínio de um domínio que já tenho,
  `int.devcomm.com.br`.
- **DNS só pela VPN.** Um dnsmasq no gateway responde os nomes da zona, e o Headscale entrega essa zona aos
  clientes. O DNS público não tem registro nenhum dela.
- **Um load balancer sem rede pública**, na frente de entradas separadas do Traefik.
- **Um único certificado wildcard do Let's Encrypt.** Os logs públicos de certificados mostram só a zona, não o
  nome de cada ferramenta.

O detalhe que mais importa: o Traefik roteia pelo nome do host. Um Ingress interno ligado por engano às entradas
públicas responderia a qualquer um que enviasse aquele nome para o IP público. Uma política de admissão do
Kubernetes recusa esse Ingress antes de ele existir.

### Lição 8: identidade no `kubectl` e na VPN

O kubeconfig admin do RKE2 é um certificado de `cluster-admin` sem identidade e sem revogação individual. Hoje ele
só existe como acesso de emergência.

- O **Pocket ID**, um binário Go com SQLite, é o provedor de identidade, com login só por passkey.
- O apiserver valida os tokens, e as permissões são dadas só por grupo.
- O **Headscale roda no gateway**, não no cluster: a VPN é o caminho para consertar o cluster e não pode cair
  junto com ele. Entra quem está no grupo `vpn`, e o login expira em 30 dias.

### Lição 9: backups fora do provedor e alertas que avisam quando tudo cai

- Snapshots do etcd no R2 a cada 6 horas, para recuperar o control plane inteiro.
- Velero diário no R2, para recuperar um namespace ou um volume sem voltar o cluster todo.
- Litestream contínuo para o banco da VPN.

Cada um tem um token próprio, com acesso a um bucket só.

Os alertas vão para o Telegram, mas saem pelo NAT do gateway: **se o gateway cair, nenhum alerta sai**. Por isso um
alerta sempre ativo pinga um serviço externo (dead man's switch), que me avisa quando os pings param.

### Lição 10: Terraform em camadas, com o mínimo de mágica

![Camadas do Terraform: infra, cluster e identity aplicadas em ordem, com state no R2](images/terraform.png)

- Três camadas aplicadas em ordem: a de infraestrutura só fala com a Hetzner, a do cluster fala com o Kubernetes
  pela VPN, e a de identidade fala com a API do Pocket ID.
- State no Cloudflare R2, com o lock nativo do Terraform, sem banco extra.
- Proteção contra deleção nos masters, no IP do gateway e na rede.
- CI só estático, sem nenhum segredo. Os applies rodam localmente, pela VPN, a partir de um plan revisado.
- Versões fixadas, inclusive o instalador do RKE2, conferido por hash.

### Os limites, com honestidade

Um cluster assim não tem SLA de ninguém. Os riscos que aceitei de olhos abertos:

- O gateway continua sendo ponto único de falha. A mitigação é recuperar rápido, não ter redundância.
- A disponibilidade das máquinas ARM oscila. Num mesmo dia, de manhã não havia nenhuma à venda, e à tarde voltou.
- Os três masters ficam na mesma localização. Os snapshots fora da Hetzner cobrem a perda dela, mas com restore
  manual.
- Upgrades do RKE2 são manuais.
- O provider do Karpenter é comunitário e usa um token com poder total sobre o projeto.

## Conclusão

Por cerca de US$ 61 por mês, este cluster tem três masters com etcd, workers elásticos, nenhum nó na internet, TLS
automático, ferramentas internas só pela VPN, backups fora do provedor, alertas que funcionam mesmo com o gateway
fora do ar e login por passkey no `kubectl` e na VPN.

Nada disso exigiu serviços gerenciados caros. Exigiu conhecer as limitações do provedor e transformar cada
contorno em código: a rota que precisa existir antes do primeiro download, o token que não pode ir para o
user_data, o load balancer que não acrescentava nada, a política que impede um erro de configuração de expor uma
ferramenta interna.

Se eu tivesse que resumir em uma lição: **custo baixo e produção não são opostos, desde que cada decisão fique
registrada**. Todas as escolhas deste projeto, com as alternativas descartadas, estão documentadas como ADRs
(Architecture Decision Records) junto do código, em [github.com/reginaldosousa/hetzner-rke2-terraform](https://github.com/reginaldosousa/hetzner-rke2-terraform).

E você, já rodou Kubernetes fora das nuvens grandes? Qual foi a pegadinha que mais te custou tempo?

<!--
Publicado em: https://reginaldosousa.com/kubernetes-production-ready-por-us-61-m%C3%AAs-o-que-aprendi-montando-um-cluster-na-hetzner-cfbc99389ecc
Versão em inglês: kubernetes-production-ready-low-cost.en.md (diagramas em blog/diagrams/en/); mantenha as duas em dia.
Formato: escrito para Medium e LinkedIn, que não renderizam tabelas Markdown; por isso só listas.
Diagramas: as fontes Mermaid estão em blog/diagrams/. Para renderizar de novo:
  for d in arquitetura fluxos terraform; do
    npx -y @mermaid-js/mermaid-cli@11.4.2 -i blog/diagrams/$d.mmd -o blog/images/$d.png -b white -s 2
  done
Detalhes técnicos e custos: docs/adr/, docs/costs.md.
-->
