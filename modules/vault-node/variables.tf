variable "region" {
  description = "AWS region for the Vault node."
  type        = string
}

variable "name" {
  description = "Name prefix for shared Vault resources."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Must support the AMI's architecture (arm64 or x86_64)."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the Vault node. Must be in the data volume's availability zone."
  type        = string
}

variable "vpc_id" {
  description = "VPC of var.subnet_id."
  type        = string
}

variable "kms_key_id" {
  description = "ID of the KMS key used for auto-unseal."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used for auto-unseal."
  type        = string
}

variable "data_volume_id" {
  description = "EBS volume holding the Raft data, mounted at /opt/vault/data."
  type        = string
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
variable "vault_version" {
  description = "Vault Community version from the HashiCorp RPM repo, e.g. 2.1.1. Changing it replaces the node."
  type        = string
}

variable "ami_name" {
  description = "Exact name of the Amazon-owned AMI, e.g. al2023-ami-2023.12.20260918.0-kernel-6.12-arm64. Changing it replaces the node."
  type        = string
}

variable "snapshot_bucket" {
  description = "S3 bucket for Raft snapshots."
  type        = string
}

variable "snapshot_bucket_arn" {
  description = "ARN of var.snapshot_bucket."
  type        = string
}

variable "snapshot_schedule" {
  description = "systemd OnCalendar expression for scheduled snapshots (one is also taken at every clean shutdown)."
  type        = string
  default     = "hourly"
}

variable "store_check_action" {
  description = "IAM action that lets the node see (metadata only) whether init output was already stored."
  type        = string

  validation {
    condition     = contains(["secretsmanager:DescribeSecret", "ssm:DescribeParameters"], var.store_check_action)
    error_message = "store_check_action must be secretsmanager:DescribeSecret or ssm:DescribeParameters."
  }
}

variable "store_check_cmd" {
  description = "Shell command that exits 0 if a node has already stored init output (never reads the value)."
  type        = string
}
