# Auto-instrumentation (ADR 0029): the operator's webhook injects an
# OpenTelemetry SDK into pods annotated with
# instrumentation.opentelemetry.io/inject-<language>: "monitoring/default".
# The pod webhook fails open, so an operator outage never blocks pod creation.
resource "helm_release" "otel_operator" {
  name       = "opentelemetry-operator"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-operator"
  version    = var.otel_operator_chart_version

  values = [yamlencode({
    manager = {
      serviceMonitor = { enabled = true }
      resources = {
        requests = { cpu = "10m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    admissionWebhooks = {
      # Webhook certificate from cert-manager rather than one Helm generates
      # on every upgrade.
      certManager      = { enabled = true }
      autoGenerateCert = { enabled = false }
      pods             = { failurePolicy = "Ignore" }
    }
  })]

  depends_on = [helm_release.cert_manager, helm_release.kube_prometheus_stack]
}

# Local chart: the Instrumentation CRD only exists once the operator is
# installed (ADR 0014).
resource "helm_release" "otel_instrumentation" {
  name      = "otel-instrumentation"
  namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  chart     = "${path.module}/charts/otel-instrumentation"

  values = [yamlencode({
    # The agent's Service routes to the collector on the pod's own node.
    endpoint    = "http://otel-agent.${kubernetes_namespace_v1.monitoring.metadata[0].name}:4318"
    sampleRatio = tostring(var.otel_trace_sample_ratio)
  })]

  depends_on = [helm_release.otel_operator, helm_release.otel_agent]
}
