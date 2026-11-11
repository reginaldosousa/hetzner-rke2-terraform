# Redis (ADR 0032): one operator for every Redis in the cluster. Instances are
# RedisReplication/Redis CRs, rendered by the OT-Container-Kit charts in each
# consumer's namespace (Harbor first, Tsuru services later).
resource "kubernetes_namespace_v1" "redis_operator" {
  metadata {
    name = "redis-operator"
  }
}

resource "helm_release" "redis_operator" {
  name       = "redis-operator"
  namespace  = kubernetes_namespace_v1.redis_operator.metadata[0].name
  repository = "https://ot-container-kit.github.io/helm-charts"
  chart      = "redis-operator"
  version    = var.redis_operator_chart_version

  values = [yamlencode({
    redisOperator = {
      imagePullPolicy = "IfNotPresent"
      # Empty: every namespace, so instances sit next to the apps using them.
      watchNamespace = ""
    }
    # The chart's default asks for half a CPU.
    resources = {
      requests = { cpu = "20m", memory = "64Mi" }
      limits   = { cpu = null, memory = "256Mi" }
    }
  })]
}

resource "kubernetes_manifest" "redis_operator_pod_monitor" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "redis-operator"
      namespace = kubernetes_namespace_v1.redis_operator.metadata[0].name
    }
    spec = {
      selector            = { matchLabels = { name = "redis-operator" } }
      podMetricsEndpoints = [{ port = "metrics" }]
    }
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
