terraform {
  required_version = ">= 1.16"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
  }

  # Local state for the demo. For real use: S3 backend with SSE-KMS and locking.
  # The state holds mount and policy settings, never secret values.
}

# Reaches Vault through an SSM port forward: run Terraform here with
# `scripts/vault-ops.sh -C <infra root> tf vault-config ...`, which opens one and
# sets VAULT_ADDR (and, with --root, VAULT_TOKEN).
provider "vault" {}
