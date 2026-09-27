# Terraform's own way into Vault: the terraform-admin role in the aws/ auth mount,
# for the operators' IAM (SSO) roles.
#
# Ownership boundary: the aws/ mount itself, the raft-snapshot role and its policy
# belong to the node bootstrap (modules/vault-node/node-files/vault-configure-snapshots.sh).
# This root only adds roles inside the mount, and the policy below denies touching
# the node's parts. That's a guardrail against mistakes, not a security boundary:
# terraform-admin can change its own policy.

locals {
  admin_role = "terraform-admin"

  # With resolve_aws_unique_ids = false, Vault matches the login's assumed-role ARN,
  # which carries no path. SSO roles live under a path
  # (role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_...), so drop it.
  caller_role_arn = replace(data.aws_iam_session_context.current.issuer_arn, "/:role\\/.*\\//", ":role/")

  # Defaulting to the caller doesn't make the binding follow whoever applies: with
  # vault_auth = "aws", only a role that is already bound can log in to apply.
  admin_role_arns = coalesce(var.admin_role_arns, [local.caller_role_arn])
}

data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

resource "vault_policy" "terraform_admin" {
  name   = local.admin_role
  policy = <<-EOT
    # Secrets engines and their settings (the data in them is not Terraform's)
    path "sys/mounts"   { capabilities = ["read"] }
    path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
    path "+/config"     { capabilities = ["create", "read", "update", "delete"] }

    # Policies
    path "sys/policies/acl"   { capabilities = ["list"] }
    path "sys/policies/acl/*" { capabilities = ["create", "read", "update", "delete"] }

    # Auth methods and their roles
    path "sys/auth"   { capabilities = ["read"] }
    path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
    path "auth/*"     { capabilities = ["create", "read", "update", "delete", "list"] }

    # The provider works with a child token of its login token
    path "auth/token/create" { capabilities = ["update"] }

    # Owned by the node bootstrap (vault-configure-snapshots.sh): hands off
    path "sys/auth/aws"                   { capabilities = ["deny"] }
    path "sys/auth/aws/*"                 { capabilities = ["deny"] }
    path "auth/aws/config/*"              { capabilities = ["deny"] }
    path "auth/aws/role/raft-snapshot"    { capabilities = ["deny"] }
    path "sys/policies/acl/raft-snapshot" { capabilities = ["deny"] }
  EOT
}

resource "vault_aws_auth_backend_role" "terraform_admin" {
  backend   = "aws" # the node's mount; not managed here
  role      = local.admin_role
  auth_type = "iam"

  bound_iam_principal_arns = local.admin_role_arns
  # Match on the ARN only: resolving it to a unique ID would need iam:GetRole, which
  # the node (whose credentials Vault uses) doesn't have. Same as raft-snapshot.
  resolve_aws_unique_ids = false

  token_policies = [vault_policy.terraform_admin.name]
  token_ttl      = 1200
  token_max_ttl  = 3600
}
