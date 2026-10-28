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
