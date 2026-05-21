output "gateway_public_ip" {
  description = "Assigned external IP allocation for the reverse-proxy VM gateway"
  value       = google_compute_instance.gateway.network_interface[0].access_config[0].nat_ip
}

output "engine_internal_ip" {
  description = "Assigned private VPC subnet IP for the central iii WebSocket engine"
  value       = google_compute_instance.engine.network_interface[0].network_ip
}

output "caller_internal_ip" {
  description = "Assigned private VPC subnet IP for the node/typescript caller-worker"
  value       = google_compute_instance.caller.network_interface[0].network_ip
}

output "inference_internal_ip" {
  description = "Assigned private VPC subnet IP for the python inference-worker running Gemma"
  value       = google_compute_instance.inference.network_interface[0].network_ip
}

output "curl_test_command" {
  description = "Utility CLI verification command string targeting API"
  value       = <<-EOT
    curl -X POST http://${google_compute_instance.gateway.network_interface[0].access_config[0].nat_ip}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"messages": [{"role": "user", "content": "What is 2 + 2?"}]}'
  EOT
}
