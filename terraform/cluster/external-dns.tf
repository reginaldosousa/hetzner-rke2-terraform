# Cloudflare token for external-dns (see dns-token.tf).
resource "kubernetes_secret_v1" "cloudflare" {
  metadata {
    name      = "external-dns-cloudflare"
    namespace = "kube-system"
  }

  data = {
    apiToken = cloudflare_account_token.dns.value
  }
}

# Publishes Ingress hosts (and Services annotated with
# external-dns.alpha.kubernetes.io/hostname) to Cloudflare, pointing at the
# ingress LB's public IPs.
resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version

  values = [yamlencode({
    provider = { name = "cloudflare" }
    env = [{
      name = "CF_API_TOKEN"
      valueFrom = {
        secretKeyRef = {
          name = kubernetes_secret_v1.cloudflare.metadata[0].name
          key  = "apiToken"
        }
      }
    }]
    sources       = ["ingress", "service"]
    domainFilters = var.external_dns_domains
    # Internal hosts (docs/adr/0027) carry the public LB's IP in their Ingress
    # status, like every Ingress. They must stay out of public DNS.
    excludeDomains = [local.internal_domain]
    # sync also deletes records, but the TXT registry limits that to records
    # this cluster created; anything else in the zone is left alone.
    policy     = "sync"
    registry   = "txt"
    txtOwnerId = local.infra.cluster_name
  })]
}
