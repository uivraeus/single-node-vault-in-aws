variable "kv_max_versions" {
  description = "Versions kept per key in secret/ (0 means Vault's default, 10)."
  type        = number
  default     = 10
}

variable "region" {
  description = "AWS region of the Vault node (signs the aws/ auth login)."
  type        = string
  default     = "eu-north-1"
}

variable "vault_auth" {
  description = "How Terraform logs in to Vault: aws (the terraform-admin role, normal use) or token (VAULT_TOKEN, for the first apply)."
  type        = string
  default     = "aws"

  validation {
    condition     = contains(["aws", "token"], var.vault_auth)
    error_message = "vault_auth must be aws or token."
  }
}

variable "admin_role_arns" {
  description = "IAM role ARNs allowed to log in as terraform-admin, without a path (arn:aws:iam::<account>:role/<name>). Defaults to the role you run Terraform with."
  type        = list(string)
  default     = null
}
