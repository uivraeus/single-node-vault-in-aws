# Secrets Manager variant.
#
# Terraform owns the *container*; the Vault instance writes the value at init.
# There is deliberately no aws_secretsmanager_secret_version, so Terraform never
# reads the root token and it never ends up in state. `terraform destroy`
# deletes the secret (immediately, or after the recovery window).

resource "aws_secretsmanager_secret" "vault_init" {
  name                    = "vault/${var.name}/init"
  description             = "Vault init output (root token + recovery keys). Written by the Vault node at first boot."
  recovery_window_in_days = var.recovery_window_in_days

  # Uses the AWS managed key aws/secretsmanager, so no extra KMS permissions are
  # needed. Set kms_key_id to a customer managed key for a key policy of your own
  # or cross-account access.
}

# Write-only for the node: it can store the init output but not read it back.
data "aws_iam_policy_document" "store_init" {
  statement {
    sid       = "WriteVaultInitOutput"
    actions   = ["secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.vault_init.arn]
  }
}

resource "aws_iam_role_policy" "store_init" {
  name   = "vault-store-init"
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.store_init.json
}

locals {
  store_name = aws_secretsmanager_secret.vault_init.name

  # Run on the node with the init JSON on stdin.
  store_init_cmd = "aws secretsmanager put-secret-value --secret-id ${local.store_name} --secret-string file:///dev/stdin"

  # Run by humans, with their own credentials.
  read_init = "aws secretsmanager get-secret-value --region ${var.region} --secret-id ${local.store_name} --query SecretString --output text"
}
