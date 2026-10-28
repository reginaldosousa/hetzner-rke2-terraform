resource "kubernetes_namespace_v1" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

# ClusterIssuers read their secrets from cert-manager's own namespace. Same
# token as external-dns: both need Zone:Read + DNS:Edit on the same zones.
resource "kubernetes_secret_v1" "cert_manager_cloudflare" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name
  }

  data = {
    apiToken = cloudflare_account_token.dns.value
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = kubernetes_namespace_v1.cert_manager.metadata[0].name
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.cert_manager_chart_version

  values = [yamlencode({
    crds = { enabled = true }
    # Check DNS-01 propagation against public resolvers, not CoreDNS, so a
    # stale cached NXDOMAIN can't stall issuance.
    extraArgs = [
      "--dns01-recursive-nameservers-only",
      "--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53",
    ]
  })]
}

# Let's Encrypt staging + prod ClusterIssuers as a local chart: the CRDs only
# exist once cert-manager is installed, which kubernetes_manifest can't plan for.
resource "helm_release" "cluster_issuers" {
  name      = "cluster-issuers"
  namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name
  chart     = "${path.module}/charts/cluster-issuers"

  values = [yamlencode({
    email    = var.acme_email
    dnsZones = var.external_dns_domains
    apiTokenSecret = {
      name = kubernetes_secret_v1.cert_manager_cloudflare.metadata[0].name
      key  = "apiToken"
    }
  })]

  depends_on = [helm_release.cert_manager]
}
