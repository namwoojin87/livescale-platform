output "namespace" {
  description = "Namespace containing the LiveScale resources."
  value       = kubernetes_namespace_v1.livescale.metadata[0].name
}

output "ingress_url" {
  description = "Ingress URL when livescale.local resolves to 172.16.8.50."
  value       = "http://${var.ingress_host}/"
}

output "smoke_test_command" {
  description = "Curl command that tests the ingress without editing DNS."
  value       = "curl -H 'Host: ${var.ingress_host}' http://172.16.8.50/health"
}
