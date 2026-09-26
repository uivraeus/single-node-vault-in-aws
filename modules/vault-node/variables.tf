variable "region" {
  description = "AWS region for the Vault node and KMS key."
  type        = string
}

variable "name" {
  description = "Name prefix for shared Vault resources."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Must match var.architecture."
  type        = string
}

variable "architecture" {
  description = "CPU architecture for the Amazon Linux 2023 AMI."
  type        = string

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "subnet_id" {
  description = "Subnet for the Vault node. Defaults to a subnet in the default VPC."
  type        = string
  default     = null
}

variable "associate_public_ip" {
  description = "Public IP for outbound access to SSM/KMS/package repos."
  type        = bool
}

variable "store_name" {
  description = "Name of the secret container used for Vault init output."
  type        = string
}

variable "store_arn" {
  description = "ARN of the secret container that the node may write."
  type        = string
}

variable "store_write_action" {
  description = "IAM action that allows the node to write the init output."
  type        = string

  validation {
    condition     = contains(["secretsmanager:PutSecretValue", "ssm:PutParameter"], var.store_write_action)
    error_message = "store_write_action must be the supported write action for Secrets Manager or Parameter Store."
  }
}

variable "store_init_cmd" {
  description = "AWS CLI command that writes JSON from stdin to the secret container."
  type        = string
}