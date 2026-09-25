variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-north-1"
}

variable "name" {
  description = "Name prefix for all resources. Also used in the secret name."
  type        = string
  default     = "vault-demo"
}

variable "instance_type" {
  description = "EC2 instance type. Must match var.architecture."
  type        = string
  default     = "t4g.small"
}

variable "architecture" {
  description = "CPU architecture for the Amazon Linux 2023 AMI."
  type        = string
  default     = "arm64"

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
  description = "Public IP for outbound access to SSM/KMS/package repos. Set false if the subnet has a NAT gateway or VPC endpoints."
  type        = bool
  default     = true
}

variable "recovery_window_in_days" {
  description = "Days a deleted secret can be restored. 0 = delete immediately on destroy (lab friendly); 7-30 = undo possible, but the name stays reserved during the window."
  type        = number
  default     = 0

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0 or between 7 and 30."
  }
}
