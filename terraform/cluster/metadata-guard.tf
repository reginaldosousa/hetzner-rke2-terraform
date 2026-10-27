# Pods must not reach the Hetzner metadata service: it serves each server's
# user_data, which holds the RKE2 server token on masters and the agent token
# on workers. Own Calico tier ahead of the default one: it only denies, and its
# Pass default hands everything else on to regular NetworkPolicies.
resource "kubernetes_manifest" "metadata_guard_tier" {
  manifest = {
    apiVersion = "crd.projectcalico.org/v1"
    kind       = "Tier"
    metadata = {
      name = "metadata-guard"
    }
    spec = {
      order         = 100
      defaultAction = "Pass"
    }
  }
}

resource "kubernetes_manifest" "deny_instance_metadata" {
  manifest = {
    apiVersion = "crd.projectcalico.org/v1"
    kind       = "GlobalNetworkPolicy"
    metadata = {
      # Tier-prefixed: older Calico releases require it outside the default tier.
      name = "metadata-guard.deny-instance-metadata"
    }
    spec = {
      tier  = "metadata-guard"
      order = 0
      # hcloud-csi reads its server ID from the metadata service. hostNetwork
      # pods bypass pod policies entirely; Pod Security keeps them in kube-system.
      selector = "!(projectcalico.org/namespace == 'kube-system' && app.kubernetes.io/name == 'hcloud-csi')"
      types    = ["Egress"]
      egress = [{
        action      = "Deny"
        destination = { nets = ["169.254.169.254/32"] }
      }]
    }
  }

  depends_on = [kubernetes_manifest.metadata_guard_tier]
}
