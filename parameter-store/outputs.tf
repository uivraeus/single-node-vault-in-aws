output "instance_id" {
  value = module.vault.instance_id
}

output "parameter_name" {
  value = aws_ssm_parameter.vault_init.name
}

output "kms_unseal_key_arn" {
  value = module.vault.kms_unseal_key_arn
}

output "cmd_shell" {
  description = "Shell on the Vault node."
  value       = module.vault.cmd_shell
}

output "cmd_port_forward" {
  description = "Forward localhost:8200 to Vault; then use VAULT_ADDR=http://127.0.0.1:8200 locally."
  value       = module.vault.cmd_port_forward
}

output "cmd_bootstrap_log" {
  description = "Follow the bootstrap on the node (run inside cmd_shell)."
  value       = module.vault.cmd_bootstrap_log
}

output "cmd_root_token" {
  description = "Export the root token locally."
  value       = "export VAULT_TOKEN=$(${local.read_init} | jq -r .root_token)"
}
