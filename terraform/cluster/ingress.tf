# Public ingress: RKE2's bundled Traefik, exposed through a Hetzner Load
# Balancer that the hcloud CCM creates from the LoadBalancer Service. The LB
# reaches the Traefik pods on the workers over the private network.
resource "kubernetes_manifest" "traefik_config" {
  manifest = {
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "rke2-traefik"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = yamlencode({
        service = {
          spec = { type = "LoadBalancer" }
          annotations = {
            "load-balancer.hetzner.cloud/name"           = "${local.infra.cluster_name}-ingress"
            "load-balancer.hetzner.cloud/location"       = local.infra.location
            "load-balancer.hetzner.cloud/type"           = "lb11"
            "load-balancer.hetzner.cloud/use-private-ip" = "true"
            # Preserve the real client IP: the LB prepends a PROXY header that
            # Traefik accepts only from inside the private network.
            "load-balancer.hetzner.cloud/uses-proxyprotocol" = "true"
          }
        }
        ports = {
          for name in ["web", "websecure"] : name => {
            proxyProtocol = { trustedIPs = [local.infra.network_cidr] }
          }
        }
      })
    }
  }
}
