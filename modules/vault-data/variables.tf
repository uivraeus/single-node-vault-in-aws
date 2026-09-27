variable "name" {
  description = "Name prefix for shared Vault resources."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the Vault node; its availability zone is where the data volume lives. Defaults to a subnet in the default VPC."
  type        = string
  default     = null
}

variable "data_volume_size" {
  description = "Size in GiB of the EBS volume holding Vault's Raft data."
  type        = number
  default     = 10
}

variable "snapshot_retention_days" {
  description = "Days to keep a Raft snapshot after a newer one replaces it."
  type        = number
  default     = 30
}
