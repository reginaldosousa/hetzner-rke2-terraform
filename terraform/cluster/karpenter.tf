# Read by the provider when it creates a server; keeps the RKE2 join token
# out of the HCloudNodeClass spec.
resource "kubernetes_secret_v1" "worker_bootstrap" {
  metadata {
    name      = "karpenter-worker-bootstrap"
    namespace = "kube-system"
  }

  data = {
    userData = local.infra.worker_user_data
  }
}

# Karpenter controller with the Hetzner cloud provider. Reuses the "hcloud"
# secret (key "token") that the masters already created for the CCM/CSI.
resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://ghcr.io/stubbi/charts"
  chart      = "karpenter-provider-hetzner"
  version    = var.karpenter_chart_version

  values = [yamlencode({
    clusterName = local.infra.cluster_name
    auth = {
      secretRef = { name = "hcloud", key = "token" }
    }
    # Run on the masters: workers only exist once Karpenter is running.
    nodeSelector = {
      "node-role.kubernetes.io/control-plane" = "true"
    }
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" },
      { key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" },
    ]
  })]
}
