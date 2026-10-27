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
          spec = {
            type = "LoadBalancer"
            # Only nodes running a Traefik pod pass the LB health check, so
            # requests never take an extra kube-proxy hop. That hop would
            # SNAT the source, and Traefik would then distrust the PROXY header.
            externalTrafficPolicy = "Local"
          }
          annotations = {
            "load-balancer.hetzner.cloud/name"           = "${local.infra.cluster_name}-ingress"
            "load-balancer.hetzner.cloud/location"       = local.infra.location
            "load-balancer.hetzner.cloud/type"           = "lb11"
            "load-balancer.hetzner.cloud/use-private-ip" = "true"
            # Keep the LB's private IP out of the Service status, or
            # external-dns would publish a 10.x address to public DNS.
            "load-balancer.hetzner.cloud/disable-private-ingress" = "true"
            # Preserve the real client IP: the LB prepends a PROXY header that
            # Traefik accepts only from inside the private network.
            "load-balancer.hetzner.cloud/uses-proxyprotocol" = "true"
          }
        }
        # Copy the LB IPs into each Ingress status, which external-dns reads.
        providers = {
          kubernetesIngress = { publishedService = { enabled = true } }
        }
        ports = {
          web = {
            proxyProtocol = { trustedIPs = [local.infra.network_cidr] }
            # Every HTTP request gets a 308 to HTTPS. DNS-01 needs no plain-HTTP
            # path, so ACME is unaffected.
            http = {
              redirections = {
                entryPoint = { to = "websecure", scheme = "https", permanent = true }
              }
            }
          }
          websecure = {
            proxyProtocol = { trustedIPs = [local.infra.network_cidr] }
          }
        }
      })
    }
  }
}
