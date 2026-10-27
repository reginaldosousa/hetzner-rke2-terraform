# Stack: o que é usado e por quê

Cada item traz o papel que cumpre neste projeto, o motivo da escolha e, quando existe, o ADR com as
alternativas descartadas.

## Infraestrutura

### Hetzner Cloud
- **Papel:** servidores, rede privada, IP primário, firewall, placement group, load balancer e volumes.
- **Por quê:** custo muito baixo por vCPU/GB, API completa, provider Terraform oficial e, o que é decisivo,
  um CCM, um CSI e um provider Karpenter disponíveis. Um cluster HA completo custa US$ 36,45/mês fixos
  ([custos](costs.md)).
- **ADR:** [0001](adr/0001-hetzner-cloud.md)

### Servidores arm64 (`cax11`)
- **Papel:** gateway, masters e workers.
- **Por quê:** `cax11` (2 vCPU, 4 GB) é o tipo mais barato que estava disponível para compra e ainda atende ao
  mínimo de um servidor RKE2. Os tipos x86 equivalentes estavam descontinuados ou esgotados na UE. As imagens
  das cargas de trabalho precisam ser multi-arch.
- **ADR:** [0010](adr/0010-arm64-cax.md)

### Ubuntu 24.04
- **Papel:** sistema operacional de todos os nós.
- **Por quê:** imagem oficial da Hetzner, suportada pelo RKE2, com cloud-init e netplan (usados para a default
  route dos nós privados). O `imageSelector` do Karpenter seleciona a mesma família.

### Rede privada hcloud + rotas
- **Papel:** a "VPC". Os nós só têm interface privada, e duas rotas de rede levam o egress e o retorno da VPN
  ao gateway.
- **Por quê:** é a forma mais barata e simples de tirar os nós da internet. A Hetzner recusa firewalls em
  servidores sem interface pública (`PrivateNetOnlyServer`), então o isolamento vem justamente de não existir
  interface pública.
- **ADR:** [0003](adr/0003-private-network-wireguard-gateway.md)

## Acesso e borda

### WireGuard
- **Papel:** única entrada administrativa (SSH, kubectl, Terraform do root `cluster`).
- **Por quê:** kernel nativo, uma porta UDP, nada responde a quem não tem chave (não há serviço "visível" para
  scanners), configuração declarativa e trivial de gerar no Terraform (provider `OJFord/wireguard`). Peers
  novos são aplicados com `wg syncconf` sem derrubar túneis.
- **ADR:** [0003](adr/0003-private-network-wireguard-gateway.md), [0009](adr/0009-gateway-config-sync.md)

### nftables
- **Papel:** NAT (masquerade) do egress dos nós e filtro de forwarding no gateway.
- **Por quê:** substituto padrão do iptables no Ubuntu 24.04, com troca atômica de ruleset (`nft -f`) e
  validação prévia (`nft -c`), o que permite atualizar o gateway em produção com segurança.

### HAProxy
- **Papel:** endpoint do control plane (`10.0.1.2:6443` e `:9345`) com health check dos três masters.
- **Por quê:** substitui um Load Balancer pago que só servia kubectl e joins. O gateway já é dependência do
  join (egress), então isso não cria um novo ponto único de falha. Faz reload gracioso e valida a configuração
  com `haproxy -c`.
- **ADR:** [0004](adr/0004-haproxy-control-plane-endpoint.md)

### IP primário reservado
- **Papel:** IPv4 público fixo do gateway.
- **Por quê:** o IP sobrevive a um rebuild do gateway, então nenhuma configuração de cliente VPN quebra.

## Kubernetes

### RKE2
- **Papel:** distribuição Kubernetes (3 servers com etcd embutido e agents nos workers).
- **Por quê:** binário único, etcd embutido, perfil seguro por padrão (CIS), instalação por `curl | sh` no
  cloud-init, CNI (Canal), Traefik e CoreDNS embutidos, e o mecanismo de *auto-deploy manifests*
  (`/var/lib/rancher/rke2/server/manifests`) que instala CCM e CSI sem passo extra. A separação entre `token` e
  `agent-token` permite que os workers entrem sem conhecer o segredo dos servers.
- **ADR:** [0002](adr/0002-rke2.md)

### Canal (CNI padrão do RKE2)
- **Papel:** rede de pods (Flannel VXLAN + políticas do Calico).
- **Por quê:** é o padrão do RKE2 e funciona como overlay, então não precisa de rotas hcloud por nó
  (`HCLOUD_NETWORK_ROUTES_ENABLED=false`), nem do limite de rotas da rede hcloud.

### hcloud Cloud Controller Manager
- **Papel:** define `providerID: hcloud://<id>`, IPs internos dos nós, remove o taint `uninitialized` e cria
  Load Balancers a partir de Services `type: LoadBalancer`.
- **Por quê:** o Karpenter exige o `providerID` `hcloud://`, e o LB de ingress depende dele. O CCM interno do
  RKE2 é desabilitado (`disable-cloud-controller: true`) porque colocaria um `rke2://` imutável antes.
- **ADR:** [0016](adr/0016-ccm-csi-auto-deploy.md)

### hcloud CSI
- **Papel:** `StorageClass` `hcloud-volumes` (Volumes da Hetzner para PVCs).
- **Por quê:** é o driver oficial e a única forma de ter armazenamento persistente em bloco no cluster.

### Karpenter + `stubbi/karpenter-provider-hetzner`
- **Papel:** cria e remove workers conforme os pods pendentes (NodePool + HCloudNodeClass).
- **Por quê:** escolhe o tipo de servidor pelo pedido real dos pods, consolida nós ociosos (economia direta) e
  dispensa gerenciar grupos de nós no Terraform. Roda nos masters porque os workers só existem depois dele.
  O provider é comunitário, e esse risco foi aceito explicitamente.
- **ADR:** [0005](adr/0005-karpenter-workers.md)

### Traefik (embutido no RKE2)
- **Papel:** ingress controller, terminação TLS e redirect HTTP→HTTPS.
- **Por quê:** já vem no RKE2 e é configurado via `HelmChartConfig`, sem outro chart para manter. Aceita PROXY
  protocol restrito à rede privada, o que preserva o IP real do cliente.
- **ADR:** [0011](adr/0011-ingress-traefik-hetzner-lb.md)

### Hetzner Load Balancer (`lb11`, via CCM)
- **Papel:** IP público de entrada para 80/443.
- **Por quê:** é a única forma de expor serviços com nós sem IP público, custa pouco e fala com os workers pela
  rede privada. É criado pelo CCM, não pelo Terraform, e por isso precisa ser removido antes de destruir o
  cluster.
- **ADR:** [0011](adr/0011-ingress-traefik-hetzner-lb.md)

### external-dns
- **Papel:** cria e remove registros A/AAAA no Cloudflare para os hosts dos Ingress.
- **Por quê:** DNS passa a seguir o cluster de forma declarativa. Com `policy: sync` e registro TXT de dono,
  ele apaga apenas o que criou, e o `domainFilters` obrigatório limita as zonas que pode tocar.
- **ADR:** [0012](adr/0012-dns-tls-cloudflare.md)

### cert-manager + Let's Encrypt (DNS-01 no Cloudflare)
- **Papel:** emite e renova certificados TLS a partir de anotações no Ingress.
- **Por quê:** DNS-01 não depende de HTTP aberto (o redirect 308 não interfere), funciona antes de o DNS
  propagar e permitiria wildcard. Reaproveita o mesmo token Cloudflare do external-dns. O issuer de staging
  existe para testar sem esbarrar nos rate limits.
- **ADR:** [0012](adr/0012-dns-tls-cloudflare.md)

## Infraestrutura como código e operação

### Terraform (≥ 1.10, < 2.0), dois roots
- **Papel:** todo o provisionamento. O root `infra` fala com a API da Hetzner, e o root `cluster` fala com o
  Kubernetes.
- **Por quê:** é a ferramenta com providers maduros para tudo aqui (hcloud, helm, kubernetes, tls, random,
  wireguard). A divisão em dois roots existe porque `cluster` só funciona com a VPN e o cluster no ar. A versão
  1.10 é necessária para `use_lockfile` no backend S3, e a 1.9 para validações entre variáveis.
- **ADR:** [0006](adr/0006-two-terraform-roots.md)

### Cloudflare R2 como backend de state
- **Papel:** guarda o state remoto (bucket `rke2-tfstate`) com lock nativo.
- **Por quê:** compatível com S3, sem custo de egress, plano gratuito generoso, e o `If-None-Match` atômico faz
  o `use_lockfile` funcionar sem DynamoDB. Como o R2 não tem versionamento, existe o `scripts/backup-state.sh`.
- **ADR:** [0007](adr/0007-state-cloudflare-r2.md)

### Helm (provider Terraform + charts locais)
- **Papel:** instala Karpenter, external-dns e cert-manager. Charts locais carregam os recursos que dependem de
  CRDs (NodeClass, NodePool, ClusterIssuers).
- **Por quê:** `kubernetes_manifest` precisa do CRD já instalado na hora do plan. Um chart local resolve isso
  e ainda pode ser verificado com `helm lint` e `helm template`.
- **ADR:** [0014](adr/0014-local-helm-charts-for-crds.md)

### cloud-init
- **Papel:** bootstrap de todos os servidores (gateway, masters e workers).
- **Por quê:** é nativo na Hetzner e no Ubuntu e roda uma vez no primeiro boot. Isso combina com
  `ignore_changes = [user_data]`, que evita rebuilds acidentais.

### Scripts shell (`scripts/`)
- `get-kubeconfig.sh`: busca o `rke2.yaml` do master-1 pela VPN e reescreve o endpoint para o HAProxy.
- `pin-master-host-keys.sh`: grava as host keys dos masters, lidas pelo gateway, em `master_known_hosts`.
- `sync-masters.sh`: envia os drop-ins do RKE2 e reinicia os masters um por vez
  ([ADR 0018](adr/0018-pod-security-baseline.md)).
- `sync-gateway.sh`: diff, validação e ativação in-place da configuração do gateway, com host key fixada.
  [ADR 0009](adr/0009-gateway-config-sync.md)
- `backup-state.sh`: guarda cópias locais dos states (mantém as 30 mais recentes).

### GitHub Actions (CI só estático)
- **Papel:** `terraform fmt`/`validate`, tflint, trivy, `helm lint --strict` e shellcheck em PRs e na `main`.
- **Por quê:** pega erros cedo sem dar ao CI acesso à VPN, ao state ou a tokens. Versões das ferramentas e
  actions são fixadas (actions por SHA).
- **ADR:** [0015](adr/0015-static-only-ci.md)

## Versões fixadas

| Componente | Variável | Valor padrão |
|---|---|---|
| RKE2 | `rke2_version` | `v1.36.5+rke2r1` |
| hcloud CCM | `ccm_chart_version` | `1.39.2` |
| hcloud CSI | `csi_chart_version` | `2.24.1` |
| karpenter-provider-hetzner | `karpenter_chart_version` | `3.0.1` |
| external-dns | `external_dns_chart_version` | `1.23.0` |
| cert-manager | `cert_manager_chart_version` | `v1.21.3` |
| Provider hcloud | `versions.tf` | `~> 1.70` |

Tudo é fixado como variável para que um upgrade seja uma mudança explícita e revisável, nunca um efeito
colateral de um `apply`.
