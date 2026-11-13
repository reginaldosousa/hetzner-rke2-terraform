# Internal apps (docs/adr/0027): names under the internal domain resolve only
# through the gateway's DNS, to the private-only ingress LB. Traefik matches
# on Host, though, so an internal host routed on the public entrypoints would
# answer anyone who sends that Host header to the public LB. This policy
# rejects any Ingress or IngressRoute for an internal host that is not bound
# to the internal entrypoints alone.
locals {
  internal_domain      = local.infra.internal_domain
  internal_entrypoints = ["internal", "internal-web"]
}

# Let's Encrypt wildcard for the zone, in Traefik's default TLS store
# (docs/adr/0028). A local chart, like the issuers it depends on.
resource "helm_release" "internal_tls" {
  name      = "internal-tls"
  namespace = "kube-system"
  chart     = "${path.module}/charts/internal-tls"

  values = [yamlencode({
    internalDomain = local.internal_domain
    # Tsuru's apps live one level deeper (ADR 0034).
    extraWildcards = local.tsuru_enabled ? ["apps"] : []
  })]

  lifecycle {
    precondition {
      # DNS-01 writes the challenge in one of the Cloudflare zones we manage.
      condition     = anytrue([for zone in var.external_dns_domains : endswith(local.internal_domain, ".${zone}")])
      error_message = "infra's internal_domain must be a subdomain of one of external_dns_domains."
    }
  }

  depends_on = [helm_release.cluster_issuers]
}

resource "kubernetes_manifest" "internal_hosts_policy" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = "internal-hosts-on-internal-entrypoints" }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [
          {
            apiGroups   = ["networking.k8s.io"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["ingresses"]
          },
          {
            apiGroups   = ["traefik.io"]
            apiVersions = ["*"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["ingressroutes"]
          },
        ]
      }
      variables = [
        {
          name       = "domain"
          expression = "'${local.internal_domain}'"
        },
        {
          name       = "allowed"
          expression = jsonencode(local.internal_entrypoints)
        },
        {
          # Ingress: any rule host in the zone. IngressRoute: any match rule
          # that mentions it (over-matching only ever means stricter).
          name       = "internal"
          expression = <<-EOT
            object.kind == 'Ingress'
              ? has(object.spec.rules) && object.spec.rules.exists(r, has(r.host) &&
                  (r.host == variables.domain || r.host.endsWith('.' + variables.domain)))
              : has(object.spec.routes) && object.spec.routes.exists(r, r.match.contains(variables.domain))
          EOT
        },
        {
          name       = "entrypoints"
          expression = <<-EOT
            object.kind == 'Ingress'
              ? (has(object.metadata.annotations) &&
                  'traefik.ingress.kubernetes.io/router.entrypoints' in object.metadata.annotations
                    ? object.metadata.annotations['traefik.ingress.kubernetes.io/router.entrypoints'].split(',').map(e, e.trim())
                    : [])
              : (has(object.spec.entryPoints) ? object.spec.entryPoints : [])
          EOT
        },
      ]
      validations = [{
        expression = "!variables.internal || (size(variables.entrypoints) > 0 && variables.entrypoints.all(e, e in variables.allowed))"
        # Without an explicit list, Traefik puts the router on the public
        # entrypoints (asDefault).
        messageExpression = "'hosts under ' + variables.domain + ' must be bound only to the internal entrypoints (' + variables.allowed.join(', ') + '): set traefik.ingress.kubernetes.io/router.entrypoints: internal on the Ingress, or spec.entryPoints on the IngressRoute'"
        reason            = "Forbidden"
      }]
    }
  }
}

resource "kubernetes_manifest" "internal_hosts_policy_binding" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = "internal-hosts-on-internal-entrypoints" }
    spec = {
      policyName        = kubernetes_manifest.internal_hosts_policy.manifest.metadata.name
      validationActions = ["Deny"]
    }
  }
}

# Tsuru apps are internal until `tsuru cname add` (ADR 0034). The router gives
# every Ingress the internal entrypoint, cnames included; this moves a cname's
# Ingress to the public one when all its hosts are outside the internal zone.
# Without it, cnames stay internal (fails closed).
resource "kubernetes_manifest" "tsuru_cname_public_policy" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "MutatingAdmissionPolicy"
    metadata   = { name = "tsuru-cname-public" }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["networking.k8s.io"]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["ingresses"]
        }]
        objectSelector = { matchLabels = { "router.tsuru.io/is-cname-ingress" = "true" } }
      }
      matchConditions = [{
        name       = "all-hosts-public"
        expression = <<-EOT
          has(object.spec.rules) && size(object.spec.rules) > 0 &&
          object.spec.rules.all(r, has(r.host) &&
            !(r.host == '${local.internal_domain}' || r.host.endsWith('.${local.internal_domain}')))
        EOT
      }]
      reinvocationPolicy = "Never"
      mutations = [{
        patchType = "ApplyConfiguration"
        applyConfiguration = {
          expression = <<-EOT
            Object{
              metadata: Object.metadata{
                annotations: {"traefik.ingress.kubernetes.io/router.entrypoints": "websecure"}
              }
            }
          EOT
        }
      }]
    }
  }
}

resource "kubernetes_manifest" "tsuru_cname_public_binding" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "MutatingAdmissionPolicyBinding"
    metadata   = { name = "tsuru-cname-public" }
    spec = {
      policyName = kubernetes_manifest.tsuru_cname_public_policy.manifest.metadata.name
    }
  }
}
