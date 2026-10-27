# Unattended-upgrades installs security patches on every node but never
# reboots. kured drains and reboots one node at a time when
# /var/run/reboot-required appears, masters included (etcd keeps quorum with
# 2 of 3), inside a night window.
resource "helm_release" "kured" {
  name       = "kured"
  namespace  = "kube-system"
  repository = "https://kubereboot.github.io/charts"
  chart      = "kured"
  version    = var.kured_chart_version

  values = [yamlencode({
    configuration = {
      period    = "1h"
      startTime = "01:00"
      endTime   = "05:00"
      timeZone  = "America/Sao_Paulo"
      # A drain blocked by a PDB gives up and retries next period instead of
      # holding the cluster-wide reboot lock forever.
      drainTimeout = "30m"
      forceReboot  = false
      concurrency  = 1
    }
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" },
      { key = "node-role.kubernetes.io/control-plane", operator = "Exists" },
      { key = "node-role.kubernetes.io/etcd", operator = "Exists" },
    ]
  })]
}
