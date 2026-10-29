# 0029. Logs e traces com OpenTelemetry, Loki e Tempo

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/otel-collector.tf terraform/cluster/loki.tf terraform/cluster/tempo.tf`

## Contexto

O cluster tinha métricas e alertas ([ADR 0021](0021-monitoring-telegram.md)), mas os logs só existiam enquanto
o pod existia (`kubectl logs`) e os Events sumiam depois de 1 h. Não havia tracing. Os workers e masters são
`cax11` (4 GB), então cada componente novo precisa caber nisso. O Grafana já existe, com login pelo Pocket ID e
acesso só pela VPN.

## Decisão

Um pipeline OpenTelemetry para os três sinais, terminando no Grafana que já existe:

- **Coleta: OpenTelemetry Collector** (imagem `contrib`, multi-arch), no namespace `monitoring`:
  - `otel-agent`, DaemonSet em todos os nós, masters inclusive. Lê `/var/log/pods` (filelog, com checkpoint
    no host), recebe OTLP dos apps por um Service com `internalTrafficPolicy: Local` (o app fala com o agent do
    próprio nó, sem hostPort) e acrescenta os atributos do pod (`k8s_attributes`).
  - `otel-cluster`, uma réplica, transforma os Events do Kubernetes em logs.
- **Logs: Loki** em modo single binary, índice e chunks no R2 (`rke2-loki`), retenção de 30 dias pelo
  compactor. Recebe OTLP nativo em `/otlp`. Não tem gateway, caches nem canary.
- **Traces: Tempo 3** em modo single binary, blocos no R2 (`rke2-tempo`), retenção de 7 dias. O
  metrics-generator manda métricas de span e o service graph ao Prometheus por remote-write.
- **Métricas: o Prometheus que já existe.** Ele liga o receiver OTLP (métricas dos apps, pelos collectors) e o
  de remote-write (Tempo), guarda exemplars e aceita amostras fora de ordem por 30 min. As métricas de nó e de
  cluster continuam vindo do node-exporter, do kube-state-metrics e do cAdvisor, e os collectors não as coletam
  de novo.
- **Auto-instrumentação: OpenTelemetry Operator.** O webhook injeta o SDK (Java, Node.js, Python, .NET) nos
  pods com `instrumentation.opentelemetry.io/inject-<linguagem>: "monitoring/default"`, apontando para o
  agent do nó, com amostragem `parentbased_traceidratio` (`otel_trace_sample_ratio`). O webhook de pods falha
  aberto: se o operator cair, os pods sobem sem instrumentação. O certificado vem do cert-manager.
- **Grafana** ganha os datasources Loki e Tempo, ligados entre si: o `trace_id` de um log abre o trace, um
  span abre os logs dele, e um exemplar num gráfico do Prometheus abre o trace.
- Credenciais do R2 seguem o padrão do Velero: um token por bucket, com escopo só nele, num Secret lido como
  variável de ambiente e expandido na configuração (`-config.expand-env`), fora dos values do Helm.
- Charts do Loki e do Tempo vêm do `grafana-community`: o chart OSS do Loki mudou para lá em março de 2026, e o
  `grafana/tempo` está deprecado.

## Alternativas consideradas

- **SigNoz ou ClickStack (ClickHouse):** uma interface só para os três sinais, mas o ClickHouse é pesado para
  nós de 4 GB e duplicaria o Grafana e o Alertmanager, que já estão configurados.
- **VictoriaMetrics, VictoriaLogs e VictoriaTraces:** mais leves, mas trocariam um Prometheus que já funciona, e
  o tracing deles é o menos maduro.
- **Mimir no lugar do Prometheus:** escala horizontal que este cluster não precisa.
- **Promtail / Grafana Alloy para logs:** o Collector já faz logs, traces e métricas num agente só, e o
  Promtail está descontinuado.
- **Volumes Hetzner em vez do R2:** sem credenciais, mas os dados ficariam presos a um volume de uma zona e
  sumiriam com ele. O R2 é barato e não cobra egress.

## Consequências

- Requests de ~1,3 GB de memória (o agent pede 128 Mi em cada nó) e dois volumes de 10 GB a mais (WAL do Loki
  e do Tempo). O agent roda também nos masters, que já estão em ~65% de memória: o limite dele (256 Mi) segura
  isso.
- Logs podem conter segredos que um app imprima. O bucket `rke2-loki` e o datasource Loki do Grafana passam a ser
  tão sensíveis quanto os próprios logs.
- O namespace `monitoring` já é `privileged` (node-exporter). O filelog usa `hostPath` ali, sem exceção nova.
- Logs do journald (rke2-server, kubelet, containerd) ficam de fora: a imagem `contrib` não tem `journalctl`.
  Quando fizer falta, entra um receiver journald com uma imagem que o tenha.
- Instrumentação Go automática (eBPF, exige privilégio) não está habilitada. Apps em Go usam o SDK direto e
  mandam OTLP para `http://otel-agent.monitoring:4318`.
- Para um app que fala com o agent, o pod precisa estar num nó com o agent pronto (`internalTrafficPolicy:
  Local`). Durante o rollout do DaemonSet, os spans daquele nó se perdem por alguns segundos.
- Os buckets `rke2-loki` e `rke2-tempo` são `prevent_destroy`. O `monitoring` continua fora do Velero: os dados
  estão no R2 e o resto é recriado pelo Terraform.
