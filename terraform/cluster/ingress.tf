# Public ingress: RKE2's bundled Traefik, exposed through a Hetzner Load
# Balancer that the hcloud CCM creates from the LoadBalancer Service. The LB
# reaches the Traefik pods on the workers over the private network.
# Internal apps (docs/adr/0027) get a second, private-only LB on separate
# entrypoints.
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
          # Private-only LB at the fixed IP the gateway's DNS answers for every
          # name under the internal domain. It carries only the internal
          # entrypoints below.
          additionalServices = {
            internal = {
              spec = { type = "LoadBalancer", externalTrafficPolicy = "Local" }
              annotations = {
                "load-balancer.hetzner.cloud/name"                   = "${local.infra.cluster_name}-ingress-internal"
                "load-balancer.hetzner.cloud/location"               = local.infra.location
                "load-balancer.hetzner.cloud/type"                   = "lb11"
                "load-balancer.hetzner.cloud/use-private-ip"         = "true"
                "load-balancer.hetzner.cloud/private-ipv4"           = local.infra.internal_ingress_ip
                "load-balancer.hetzner.cloud/disable-public-network" = "true"
                "load-balancer.hetzner.cloud/ipv6-disabled"          = "true"
                "load-balancer.hetzner.cloud/uses-proxyprotocol"     = "true"
              }
            }
          }
        }
        # Copy the LB IPs into each Ingress status, which external-dns reads.
        providers = {
          kubernetesIngress = { publishedService = { enabled = true } }
        }
        ports = {
          web = {
            asDefault     = true
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
            # Routers that name no entrypoint stay public-only, never on the
            # internal LB.
            asDefault     = true
            proxyProtocol = { trustedIPs = [local.infra.network_cidr] }
          }
          # Only on the internal LB. Routers opt in with the annotation
          # traefik.ingress.kubernetes.io/router.entrypoints: internal, and the
          # admission policy in internal-apps.tf requires it for internal hosts.
          internal = {
            port          = 8444
            exposedPort   = 443
            expose        = { default = false, internal = true }
            proxyProtocol = { trustedIPs = [local.infra.network_cidr] }
            http          = { tls = { enabled = true } }
          }
          internal-web = {
            port          = 8001
            exposedPort   = 80
            expose        = { default = false, internal = true }
            proxyProtocol = { trustedIPs = [local.infra.network_cidr] }
            http = {
              redirections = {
                entryPoint = { to = "internal", scheme = "https", permanent = true }
              }
            }
          }
        }
      })
    }
  }
}
