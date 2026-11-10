# 0034. Tsuru como PaaS, com apps internos e publicação por cname

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/tsuru.tf terraform/cluster/internal-apps.tf`

## Contexto

Queremos que um time faça deploy de um app sem escrever manifestos: `tsuru app create` e `tsuru app deploy`. O
Tsuru precisa de um MongoDB ([ADR 0030](0030-mongodb-percona-operator.md)), de um registry
([ADR 0033](0033-harbor-registry.md)) e de um router que crie os Ingresses dos apps.

Requisitos:

- Todo app nasce **interno**, em `<app>.apps.int.devcomm.com.br`, alcançável só pela VPN
  ([ADR 0027](0027-internal-apps-dns.md), [ADR 0028](0028-internal-apps-public-subdomain.md)).
- Um app só fica **público** quando alguém roda `tsuru cname add <host>` com um nome fora da zona interna, e volta a
  ser interno com `tsuru cname remove`.

O `kubernetes-router` (modo `ingress`) cria um Ingress para o host do app e **um Ingress separado por cname**, com o
label `router.tsuru.io/is-cname-ingress=true`. As anotações de `-k8s-annotations` vão para os dois.

## Decisão

- **Charts do Tsuru, um por componente** (`tsuru-api`, `kubernetes-router`, `deploy-agent`), e não o
  `tsuru-stack`: ele traz MongoDB da Bitnami, ingress-nginx, senhas fixas e `debug: true`.
- **API em `tsuru-system`**, só pela VPN em `https://tsuru.int.devcomm.com.br` (entrypoint `internal`). Os segredos
  (URI do MongoDB, autorização do router) vêm de um Secret como variáveis de ambiente, que a configuração do Tsuru
  expande (`$MONGODB_URL`), e não ficam no ConfigMap. O Tsuru cria sozinho o cluster `local` (in-cluster) e o pool
  `local` na primeira subida.
- **Router com Traefik:** `kubernetes-router` em modo `ingress`, classe `traefik`, domínio
  `apps.int.devcomm.com.br`, e as anotações `router.entrypoints=internal` e `router.tls=true` em todo Ingress que
  cria. Um wildcard `*.apps.int.devcomm.com.br` entra no TLSStore padrão do Traefik (`charts/internal-tls`). A
  política de admissão que já existe garante que nenhum host da zona interna chegue aos entrypoints públicos.
- **Publicação por cname:** uma **MutatingAdmissionPolicy** (`tsuru-cname-public`, em `internal-apps.tf`) troca
  `router.entrypoints` para `websecure` (o `web` já redireciona tudo para HTTPS) nos Ingresses de cname cujos hosts estão **todos fora** da zona interna.
  O external-dns publica o host se a zona for uma das `external_dns_domains`; para outros domínios, o dono aponta
  um CNAME para o LB público. O certificado é pedido com `tsuru certificate set -a <app> -c <host> -i
  letsencrypt-prod`, que faz o router criar um Certificate do cert-manager.
- **Build com BuildKit no deploy-agent**, num namespace próprio, `tsuru-build`, com Pod Security `privileged` (o
  BuildKit precisa disso). É a terceira exceção ao baseline, depois de `monitoring` e `velero`. Imagens vão para o
  projeto `tsuru` do Harbor com o robot do root `registry`.
- **Pull nos apps:** o Tsuru cria o imagePullSecret dos apps a partir do `docker-config-json` do cluster. Esse valor
  é um JSON, e a configuração do Tsuru transforma qualquer valor que comece com `{` em objeto, então ele é gravado
  nos dados do cluster (`tsuru cluster update`) no bootstrap, e não no arquivo de configuração.
- Redis para os apps virá como serviço do Tsuru sobre o operator do [ADR 0032](0032-redis-operator.md), num PR
  futuro (precisa de um broker).

## Alternativas consideradas

- **`tsuru-stack`:** pronto para testar, inseguro para manter.
- **Dois routers (um interno, um público):** o `tsuru cname add` vale para todos os routers do app, e o host padrão
  do router público seria público desde o início.
- **Modo `gateway-api` do router:** cria um ListenerSet por cname, recurso experimental da Gateway API que o
  Traefik do RKE2 não serve.
- **Kyverno para a mutação:** mais um controller no cluster. A MutatingAdmissionPolicy é nativa no Kubernetes 1.36.
- **Knative, OpenFaaS, Coolify ou Dokku:** ou não são PaaS de git-push para vários times, ou não rodam sobre o
  cluster que já existe.

## Consequências

- Um host fora da zona interna passa a ser público no momento do `tsuru cname add`. Quem pode adicionar cnames pode
  publicar um app: no Tsuru, isso é a permissão `app.update.cname.add`, que só os papéis de deploy têm.
- Se a MutatingAdmissionPolicy sair (ou o label do router mudar), os cnames ficam só no entrypoint interno: falha
  fechada.
- O BuildKit privilegiado roda código do build dos apps (Dockerfile, buildpacks). Um build malicioso pode escapar
  para o nó. O namespace `tsuru-build` e os nós dele são tão confiáveis quanto quem faz deploy.
- A senha do usuário `tsuru` no MongoDB e a do router ficam em Secrets e no state do `cluster`. O JSON de pull fica
  nos dados do cluster, no MongoDB.
- Memória: API ~256 Mi, router ~64 Mi, deploy-agent ~128 Mi, BuildKit até 2 Gi durante um build.
