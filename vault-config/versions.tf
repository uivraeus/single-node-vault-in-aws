terraform {
  required_version = ">= 1.16"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }

  # Local state for the demo. For real use: S3 backend with SSE-KMS and locking.
  # The state holds mount, policy and role settings, never secret values.
}

# Reaches Vault through an SSM port forward: run Terraform here with
# `scripts/vault-ops.sh -C <infra root> tf vault-config ...`, which opens one and
# sets VAULT_ADDR.
#
# vault_auth = "aws" (default): log in to the terraform-admin role in the aws/ auth
# mount with your own AWS credentials. That role is created by this root, so the
# very first apply uses vault_auth = "token" with a short-lived root token
# (`vault-ops.sh tf --root ...` sets both up).
provider "vault" {
  dynamic "auth_login_aws" {
    for_each = var.vault_auth == "aws" ? [1] : []
    content {
      role = local.admin_role
      # Vault sends the signed request on to the global STS endpoint (the aws/
      # mount has no sts_endpoint/sts_region of its own), which only accepts
      # us-east-1 signatures. Signing for the node's region fails with
      # "Credential should be scoped to a valid region".
      aws_region = "us-east-1"
    }
  }
}

provider "aws" {
  region = var.region
}
