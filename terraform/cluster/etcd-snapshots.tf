# S3 settings for the masters' scheduled etcd snapshots (etcd-s3-config-secret
# in their RKE2 config). A Secret rather than user_data, like the hcloud token:
# pods could read user_data from the metadata service. The R2 token should be
# scoped to Object Read & Write on var.etcd_s3_bucket only.
resource "kubernetes_secret_v1" "etcd_s3" {
  metadata {
    name      = local.infra.etcd_s3_config_secret
    namespace = "kube-system"
  }

  type = "etcd.k3s.cattle.io/s3-config-secret"

  data = {
    "etcd-s3-endpoint"           = var.etcd_s3_endpoint
    "etcd-s3-bucket"             = var.etcd_s3_bucket
    "etcd-s3-folder"             = local.infra.cluster_name
    "etcd-s3-region"             = "auto"
    "etcd-s3-bucket-lookup-type" = "path"
    "etcd-s3-access-key"         = var.etcd_s3_access_key
    "etcd-s3-secret-key"         = var.etcd_s3_secret_key
    # Per master; snapshots run every 6h, so 28 = 7 days.
    "etcd-s3-retention" = "28"
  }
}
