# Daily backups of Kubernetes objects and pod volumes to R2 (ADR 0022). The
# etcd snapshots (ADR 0019) restore the whole control plane; Velero restores
# single namespaces and, unlike etcd, the data in volumes.
resource "cloudflare_r2_bucket" "velero" {
  account_id = var.cloudflare_account_id
  name       = var.velero_bucket
  location   = "weur"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_account_token" "velero" {
  account_id = var.cloudflare_account_id
  name       = "${local.infra.cluster_name}-velero"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one(data.cloudflare_account_api_token_permission_groups_list.r2_object_write.result).id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.velero.name}" = "*"
    })
  }]
}

# The node agent reads pod volumes from the host (hostPath), so this namespace
# is an explicit exception to the Pod Security baseline (ADR 0018).
resource "kubernetes_namespace_v1" "velero" {
  metadata {
    name = "velero"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "kubernetes_secret_v1" "velero_r2" {
  metadata {
    name      = "velero-r2"
    namespace = kubernetes_namespace_v1.velero.metadata[0].name
  }

  data = {
    cloud = <<-EOT
      [default]
      aws_access_key_id=${cloudflare_account_token.velero.id}
      aws_secret_access_key=${sha256(cloudflare_account_token.velero.value)}
    EOT
  }
}

resource "helm_release" "velero" {
  name       = "velero"
  namespace  = kubernetes_namespace_v1.velero.metadata[0].name
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  version    = var.velero_chart_version

  values = [yamlencode({
    initContainers = [{
      name            = "velero-plugin-for-aws"
      image           = "velero/velero-plugin-for-aws:${var.velero_aws_plugin_version}"
      imagePullPolicy = "IfNotPresent"
      volumeMounts    = [{ mountPath = "/target", name = "plugins" }]
    }]

    credentials = { existingSecret = kubernetes_secret_v1.velero_r2.metadata[0].name }

    configuration = {
      backupStorageLocation = [{
        name     = "default"
        provider = "aws"
        bucket   = cloudflare_r2_bucket.velero.name
        prefix   = local.infra.cluster_name
        default  = true
        config = {
          region           = "auto"
          s3Url            = "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
          s3ForcePathStyle = "true"
          # R2 rejects the AWS SDK's default CRC32 request checksums.
          checksumAlgorithm = ""
        }
      }]
      uploaderType = "kopia"
    }

    # Hetzner volumes have no snapshot API Velero can use; volumes are copied
    # file by file by the node agent instead.
    snapshotsEnabled = false
    deployNodeAgent  = true

    schedules = {
      daily = {
        # 23:00 in São Paulo, before kured's 01:00-05:00 reboot window.
        schedule = "0 2 * * *"
        template = {
          ttl                      = "168h"
          storageLocation          = "default"
          defaultVolumesToFsBackup = true
          # Everything in it is recreated by Terraform, and Prometheus' TSDB
          # would be most of each backup.
          excludedNamespaces = [kubernetes_namespace_v1.monitoring.metadata[0].name]
        }
      }
    }

    metrics = {
      serviceMonitor = { enabled = true }
      prometheusRule = {
        enabled = true
        spec = [
          {
            alert       = "VeleroBackupFailed"
            expr        = "increase(velero_backup_failure_total{schedule!=\"\"}[1h]) > 0"
            labels      = { severity = "warning" }
            annotations = { summary = "Velero backup {{ $labels.schedule }} failed." }
          },
          {
            alert       = "VeleroNoRecentBackup"
            expr        = "time() - velero_backup_last_successful_timestamp{schedule!=\"\"} > 36 * 3600"
            for         = "15m"
            labels      = { severity = "critical" }
            annotations = { summary = "No successful Velero backup of {{ $labels.schedule }} in 36h." }
          },
        ]
      }
    }
  })]

  # The ServiceMonitor and PrometheusRule CRDs come from kube-prometheus-stack.
  depends_on = [helm_release.kube_prometheus_stack]
}
