output "tsuru_registry" {
  description = "Harbor robot for Tsuru; set as tsuru_registry in terraform/cluster (tsuru-registry.auto.tfvars.json, docs/operations.md)."
  value = {
    server   = trimprefix(local.cluster.harbor_url, "https://")
    project  = harbor_project.tsuru.name
    username = harbor_robot_account.tsuru.full_name
    password = random_password.tsuru_robot.result
  }
  sensitive = true
}
