output "instance_id" {
  value = aws_instance.vault.id
}

output "secret_name" {
  value = aws_secretsmanager_secret.vault_init.name
}

output "kms_unseal_key_arn" {
  value = aws_kms_key.vault_unseal.arn
}

output "cmd_shell" {
  description = "Shell on the Vault node."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.vault.id}"
}

output "cmd_port_forward" {
  description = "Forward localhost:8200 to Vault; then use VAULT_ADDR=http://127.0.0.1:8200 locally."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.vault.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=8200,localPortNumber=8200"
}

output "cmd_bootstrap_log" {
  description = "Follow the bootstrap on the node (run inside cmd_shell)."
  value       = "sudo tail -f /var/log/vault-bootstrap.log"
}

output "cmd_root_token" {
  description = "Export the root token locally."
  value       = "export VAULT_TOKEN=$(${local.read_init} | jq -r .root_token)"
}
