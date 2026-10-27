# 0021. Monitoramento com kube-prometheus-stack e alertas no Telegram

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/monitoring.tf`

## Contexto

O cluster só tinha o metrics-server. Ninguém ficaria sabendo se um nó saísse do ar, se o etcd perdesse um
membro ou enchesse, se um volume lotasse ou se um workload ficasse reiniciando.

## Decisão

- **kube-prometheus-stack** no namespace `monitoring`: Prometheus (15 dias, volume de 20 GB), Alertmanager,
  Grafana, kube-state-metrics e node-exporter em todos os nós, masters inclusive. As regras padrão do chart
  cobrem nós, etcd, apiserver, kubelet, volumes e workloads.
- **Control plane:** os masters expõem as métricas do etcd (`:2381`), do controller-manager e do scheduler num
  drop-in (`templates/master/30-metrics.yaml`, aplicado com `sync-masters.sh`), e o Prometheus as lê pelos IPs
  fixos dos masters. As do kube-proxy ficam de fora porque o RKE2 só as serve em localhost.
- **Alertas no Telegram.** O token do bot e a URL do dead man's switch ficam num Secret montado como arquivo,
  fora dos values do Helm.
- **Dead man's switch:** os alertas saem pelo NAT do gateway, então um gateway morto (ou um Alertmanager
  morto) é silencioso. O alerta `Watchdog`, sempre ativo, vai a cada minuto para uma URL externa opcional
  (`deadmans_switch_url`, por exemplo healthchecks.io), que avisa quando os pings param.
- O namespace `monitoring` é `privileged`: o node-exporter precisa de `hostNetwork`, `hostPID` e `hostPath`. É a
  exceção explícita prevista no [ADR 0018](0018-pod-security-baseline.md).
- O Grafana não tem Ingress: acesso por `kubectl port-forward` pela VPN, com a senha num Secret gerado pelo
  Terraform.

## Alternativas consideradas

- **Serviço gerenciado (Grafana Cloud etc.):** tiraria o monitoramento de dentro do cluster que ele observa, mas
  enviaria métricas para fora e tem custo por série. Pode vir depois.
- **Email:** exige um relay SMTP; o Telegram só precisa de um bot.

## Consequências

- Uns 1,5 GB de memória e dois volumes Hetzner (30 GB) a mais.
- Sem `deadmans_switch_url`, a queda do gateway continua invisível até alguém notar.
- O gateway em si não é monitorado por dentro (ele não é um nó). A queda dele aparece pelo dead man's switch e
  pela falha do `kubectl`.
