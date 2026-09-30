terraform {
  required_version = ">= 1.16"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
  }

  # Local state for the demo. For real use: S3 backend with SSE-KMS and locking.
  # The state holds mount settings, never secret values.
}

# Reaches Vault through an SSM port forward, with a short-lived root token: run
# Terraform here with `scripts/vault-ops.sh -C <infra root> tf ../vault-config ...`,
# which sets VAULT_ADDR and VAULT_TOKEN for the run.
provider "vault" {}
