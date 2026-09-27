# Vault server config. The KMS key and region come from /etc/vault.d/vault.env
# (VAULT_AWSKMS_SEAL_KEY_ID, AWS_REGION), which Terraform generates, so this file
# is the same on every node.
ui            = true
disable_mlock = true
api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "http://127.0.0.1:8201"

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-1"
}

# Demo: loopback only, no TLS. Reach it through an SSM session or SSM port
# forwarding. Use TLS for anything beyond a single-node lab.
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

seal "awskms" {}
