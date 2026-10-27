# kubectl over OIDC (docs/adr/0023): the apiserver maps Pocket ID groups to
# "oidc:<group>", and access is granted to groups only. Usernames are the
# immutable "sub", so never bind a User subject by name.
resource "kubernetes_cluster_role_binding_v1" "oidc_admins" {
  metadata {
    name = "oidc-cluster-admins"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "oidc:${var.oidc_admin_group}"
  }
}
