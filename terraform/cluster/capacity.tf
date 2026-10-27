# Karpenter only launches workers for pending pods, so a quiet cluster shrinks
# to one worker, and that one worker becomes the only Traefik target behind the
# ingress LB. These placeholder pods keep var.min_workers workers alive, one
# per location. Their priority is below every real
# workload: the scheduler evicts them for real pods, and Karpenter then
# launches a new node for the evicted placeholder.
resource "kubernetes_priority_class_v1" "placeholder" {
  metadata {
    name = "worker-placeholder"
  }
  value          = -10
  global_default = false
  description    = "Placeholder pods that keep a minimum number of workers; preempted by anything."
}

resource "kubernetes_namespace_v1" "capacity" {
  metadata {
    name = "capacity"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "kubernetes_deployment_v1" "worker_placeholder" {
  metadata {
    name      = "worker-placeholder"
    namespace = kubernetes_namespace_v1.capacity.metadata[0].name
  }

  spec {
    replicas = var.min_workers

    # A rolling update would deadlock: the surge pod can't share a location
    # with the old pods it is replacing.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "worker-placeholder" }
    }

    template {
      metadata {
        labels = { app = "worker-placeholder" }
      }

      spec {
        priority_class_name              = kubernetes_priority_class_v1.placeholder.metadata[0].name
        termination_grace_period_seconds = 0
        automount_service_account_token  = false

        # One per location (and so one per worker). A required anti-affinity,
        # not a topology spread: the scheduler only knows locations that
        # already have a node, so a spread is satisfied by a second node in
        # the same location. With this the pod can't fit any existing node
        # and Karpenter launches one in another location.
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              topology_key = "topology.kubernetes.io/zone"
              label_selector {
                match_labels = { app = "worker-placeholder" }
              }
            }
          }
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 65535
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "pause"
          image = "registry.k8s.io/pause:3.10"

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { memory = "16Mi" }
          }

          # Set here too: the provider writes runAsNonRoot=false on the
          # container when unset, which overrides the pod-level true.
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  # Karpenter may take a few minutes to launch the second worker.
  wait_for_rollout = false

  depends_on = [helm_release.nodepools]
}
