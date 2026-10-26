# API token + network for the CCM, CSI driver and Karpenter. Created here
# rather than in cloud-init so it never appears in instance metadata.
resource "kubernetes_secret_v1" "hcloud" {
  metadata {
    name      = "hcloud"
    namespace = "kube-system"
  }

  data = {
    token   = local.infra.hcloud_token
    network = tostring(local.infra.network_id)
  }
}

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

# Karpenter controller with the Hetzner cloud provider, reusing the "hcloud" Secret.
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

  depends_on = [kubernetes_secret_v1.hcloud]
}
