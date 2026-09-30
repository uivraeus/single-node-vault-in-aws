variable "kv_max_versions" {
  description = "Versions kept per key in secret/ (0 means Vault's default, 10)."
  type        = number
  default     = 10
}
