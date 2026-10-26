# HCloudNodeClass + NodePool as a tiny local chart: the CRDs only exist once
# the karpenter release is installed, which kubernetes_manifest can't plan for.
resource "helm_release" "nodepools" {
  name      = "karpenter-nodepools"
  namespace = "kube-system"
  chart     = "${path.module}/charts/nodepools"

  values = [yamlencode({
    clusterName = local.infra.cluster_name
    location    = local.infra.location
    networkID   = tonumber(local.infra.network_id)
    sshKeyID    = tonumber(local.infra.ssh_key_id)
    cpuLimit    = var.nodepool_cpu_limit
    userDataSecret = {
      namespace = kubernetes_secret_v1.worker_bootstrap.metadata[0].namespace
      name      = kubernetes_secret_v1.worker_bootstrap.metadata[0].name
      key       = "userData"
    }
  })]

  depends_on = [helm_release.karpenter]
}
