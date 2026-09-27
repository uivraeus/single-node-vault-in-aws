# KV v2 at secret/. Terraform owns the mount and its settings; secret values are
# written by people and apps, never through Terraform (they would end up in state).
resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "KV v2 for team and app secrets (managed by vault-config)"
}

resource "vault_kv_secret_backend_v2" "secret" {
  mount        = vault_mount.secret.path
  max_versions = var.kv_max_versions
}
