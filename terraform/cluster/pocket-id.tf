# Pocket ID: the OIDC provider for kubectl (and later the VPN), passkey-only
# (docs/adr/0023). Public on purpose once set up: a login has to work before
# any tunnel is up. Its URL is the issuer the kube-apiserver trusts, so it comes from infra.
locals {
  pocket_id_host = trimprefix(local.infra.oidc_issuer_url, "https://")
}

resource "kubernetes_namespace_v1" "pocket_id" {
  metadata {
    name = "pocket-id"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# Encrypts the signing keys in the database. Losing it makes the data
# unreadable; it lives in the Terraform state (and Velero's copy of the Secret).
resource "random_bytes" "pocket_id_encryption_key" {
  length = 32
}

resource "kubernetes_secret_v1" "pocket_id" {
  metadata {
    name      = "pocket-id"
    namespace = kubernetes_namespace_v1.pocket_id.metadata[0].name
  }

  data = {
    # Read as a file, byte for byte: base64 has no trailing newline.
    encryption-key = random_bytes.pocket_id_encryption_key.base64
  }
}

# SQLite on a Hetzner volume, so one replica. Velero copies it daily (ADR 0022).
resource "kubernetes_persistent_volume_claim_v1" "pocket_id" {
  metadata {
    name      = "pocket-id-data"
    namespace = kubernetes_namespace_v1.pocket_id.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = "10Gi" } # Hetzner's minimum volume size
    }
  }

  wait_until_bound = false # WaitForFirstConsumer: binds when the pod schedules
}

resource "kubernetes_deployment_v1" "pocket_id" {
  metadata {
    name      = "pocket-id"
    namespace = kubernetes_namespace_v1.pocket_id.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "pocket-id" }
    }
    # The volume is ReadWriteOnce; a rolling update would wait on it forever.
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = { app = "pocket-id" }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 65532 # distroless "nonroot"
          run_as_group    = 65532
          fs_group        = 65532
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "pocket-id"
          image = "ghcr.io/pocket-id/pocket-id:${var.pocket_id_version}-distroless"

          env {
            name  = "APP_URL"
            value = local.infra.oidc_issuer_url
          }
          # Client IPs (audit log, rate limits) come from Traefik's
          # X-Forwarded-For; only trust it from the pod network.
          env {
            name  = "TRUST_PROXY"
            value = "10.42.0.0/16"
          }
          env {
            name  = "ENCRYPTION_KEY_FILE"
            value = "/run/secrets/pocket-id/encryption-key"
          }
          env {
            name  = "ANALYTICS_DISABLED"
            value = "true"
          }

          port {
            container_port = 1411
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
          volume_mount {
            name       = "secret"
            mount_path = "/run/secrets/pocket-id"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 1411
            }
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 1411
            }
            initial_delay_seconds = 30
          }

          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { memory = "256Mi" }
          }

          # The provider writes runAsNonRoot=false here unless set, overriding
          # the pod-level value and failing the restricted policy.
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.pocket_id.metadata[0].name
          }
        }
        volume {
          name = "secret"
          secret {
            secret_name = kubernetes_secret_v1.pocket_id.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "pocket_id" {
  metadata {
    name      = "pocket-id"
    namespace = kubernetes_namespace_v1.pocket_id.metadata[0].name
  }

  spec {
    selector = { app = "pocket-id" }
    port {
      port        = 80
      target_port = 1411
    }
  }
}

# Until the first admin exists, /setup lets anyone create it (and so join
# k8s-admins). The allowlist holds the operator's public IP through that window;
# Traefik sees real client IPs via the LB's PROXY header. Setup can't go through
# a port-forward: passkeys are bound to the public host name.
resource "kubernetes_manifest" "pocket_id_allowlist" {
  count = length(var.pocket_id_allowed_cidrs) > 0 ? 1 : 0

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "allowlist"
      namespace = kubernetes_namespace_v1.pocket_id.metadata[0].name
    }
    spec = {
      ipAllowList = { sourceRange = var.pocket_id_allowed_cidrs }
    }
  }
}

# external-dns publishes the host; cert-manager issues the certificate.
resource "kubernetes_ingress_v1" "pocket_id" {
  metadata {
    name      = "pocket-id"
    namespace = kubernetes_namespace_v1.pocket_id.metadata[0].name
    annotations = merge({
      "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      }, length(var.pocket_id_allowed_cidrs) == 0 ? {} : {
      "traefik.ingress.kubernetes.io/router.middlewares" = "${kubernetes_namespace_v1.pocket_id.metadata[0].name}-allowlist@kubernetescrd"
    })
  }

  spec {
    ingress_class_name = "traefik"
    tls {
      hosts       = [local.pocket_id_host]
      secret_name = "pocket-id-tls"
    }
    rule {
      host = local.pocket_id_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.pocket_id.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
