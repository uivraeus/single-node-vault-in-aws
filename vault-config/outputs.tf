output "kv_mount" {
  value = vault_mount.secret.path
}

output "admin_role_arns" {
  description = "IAM roles that can log in to Vault as terraform-admin."
  value       = local.admin_role_arns
}
