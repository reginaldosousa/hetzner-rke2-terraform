# 0020. Mínimo de workers com pods placeholder e reboots automáticos com kured

- **Status:** Aceito
- **Commits:** ver `git log -- terraform/cluster/capacity.tf terraform/cluster/kured.tf`

## Contexto

O Karpenter só cria workers para pods pendentes. Com pouca carga, o cluster encolheu para **um** worker
(`fsn1`), que concentrava o único Traefik por trás do LB de ingress, além do cert-manager, do external-dns e do
controller do CSI. A queda desse nó, ou uma consolidação, derrubava todo o ingress.

Os nós rodam unattended-upgrades (patches de segurança instalados), mas ninguém os reinicia: kernel e libc
corrigidos só valem depois de um reboot. Os workers são trocados a cada 30 dias (`expireAfter`), os masters nunca.

## Decisão

- **Piso de workers:** um Deployment de pods `pause` (`capacity/worker-placeholder`, `min_workers` réplicas,
  padrão 2) com anti-afinidade por localização. A PriorityClass é negativa: qualquer pod real
  despeja um placeholder, e o Karpenter cria um nó novo para o placeholder despejado. Os placeholders seguem o
  perfil `restricted`.
- **Disrupção no NodePool:** `expireAfter: 720h` explícito, `consolidateAfter: 5m` e budget de **um** nó por vez,
  para que a consolidação ou a expiração nunca tirem todos os Traefik de uma vez.
- **kured** em todos os nós, masters inclusive: reinicia um nó por vez quando existe `/var/run/reboot-required`,
  entre 01:00 e 05:00 (America/Sao_Paulo). O drain desiste depois de 30 min e tenta de novo no período seguinte,
  sem forçar.

## Alternativas consideradas

- **Réplicas e PDBs só nos workloads:** um PDB não cria nós, e com um worker só o PDB apenas bloqueia o drain.
- **Um segundo NodePool com nós fixos:** o provider não tem conceito de mínimo, e servidores fora do Karpenter
  perderiam o ciclo de expiração.
- **system-upgrade-controller com planos de SO:** mais peças para o mesmo efeito. Ele continua sendo a opção para
  upgrades do RKE2 ([operations](../operations.md#upgrades)).

## Consequências

- Custo fixo de um segundo `cax11`.
- Um placeholder por localização, por anti-afinidade **obrigatória** na zona (`min_workers` ≤ número de
  `worker_locations`), e o NodePool declara as `worker_locations` como zonas. Um topology spread não basta: o
  scheduler e o Karpenter só conhecem localizações que já têm nós, e o segundo worker nasceu em `fsn1`, junto do
  primeiro. O Deployment usa `Recreate`, porque um rolling update travaria na anti-afinidade.
- Se uma localização ficar sem capacidade, um placeholder fica `Pending` (spread `DoNotSchedule`). Isso não afeta
  workloads reais e aparece em `kubectl -n capacity get pods`.
- Durante o reboot de um master o etcd fica com 2 de 3 membros. O kured nunca reinicia dois nós ao mesmo tempo.
- Workloads de um réplica só (cert-manager, external-dns) têm alguns segundos de indisponibilidade em cada
  reboot ou troca de nó, o que eles toleram.
