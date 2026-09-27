variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-north-1"
}

variable "name" {
  description = "Name prefix for all resources. Also used in the parameter name."
  type        = string
  default     = "vault-demo"
}

variable "instance_type" {
  description = "EC2 instance type. Must support the AMI's architecture (see ami_name)."
  type        = string
  default     = "t4g.small"
}

variable "subnet_id" {
  description = "Subnet for the Vault node; the data volume lives in its availability zone. Changing the zone means a new, empty data volume. Defaults to a subnet in the default VPC."
  type        = string
  default     = null
}

variable "associate_public_ip" {
  description = "Public IP for outbound access to SSM/KMS/package repos. Set false if the subnet has a NAT gateway or VPC endpoints."
  type        = bool
  default     = true
}

variable "vault_version" {
  description = "Vault Community version. Changing it replaces the node."
  type        = string
  default     = "2.1.1"
}

variable "ami_name" {
  description = "Exact Amazon-owned AMI name (release, kernel, architecture). Changing it replaces the node."
  type        = string
  default     = "al2023-ami-2023.12.20260918.0-kernel-6.12-arm64"
}
