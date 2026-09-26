# SSM Parameter Store variant.
#
# Terraform owns the *container*; the Vault instance overwrites the value at init.
# A parameter can't exist without a value, so Terraform creates it with a
# placeholder through the write-only attribute `value_wo`: the value is sent once
# and never read back into state. With the plain `value` attribute (even with
# ignore_changes) the provider would read the decrypted root token into state on
# every refresh.
# `terraform destroy` deletes the parameter immediately (there is no recovery window).

resource "aws_ssm_parameter" "vault_init" {
  name        = "/vault/${var.name}/init"
  description = "Vault init output (root token + recovery keys). Written by the Vault node at first boot."
  type        = "SecureString"
  tier        = "Standard" # 4 KB is plenty for the init JSON

  # WARNING: bumping value_wo_version writes the placeholder again and
  # overwrites the stored root token and recovery keys.
  value_wo         = jsonencode({ status = "pending vault init" })
  value_wo_version = 1

  # Uses the AWS managed key aws/ssm, so no extra KMS permissions are needed.
  # With a customer managed key (key_id), the node also needs kms:Encrypt on it
  # and the put-parameter call below must pass --key-id.
}

locals {
  store_name         = aws_ssm_parameter.vault_init.name
  store_arn          = aws_ssm_parameter.vault_init.arn
  store_write_action = "ssm:PutParameter"

  # Run on the node with the init JSON on stdin.
  store_init_cmd = "aws ssm put-parameter --name ${local.store_name} --type SecureString --overwrite --value file:///dev/stdin"

  # Run by humans, with their own credentials.
  read_init = "aws ssm get-parameter --region ${var.region} --name ${local.store_name} --with-decryption --query Parameter.Value --output text"
}
