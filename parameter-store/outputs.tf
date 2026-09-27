output "region" {
  value = var.region
}

output "instance_id" {
  value = module.node.instance_id
}

output "parameter_name" {
  value = aws_ssm_parameter.vault_init.name
}

output "kms_unseal_key_arn" {
  value = module.data.kms_key_arn
}

output "data_volume_id" {
  value = module.data.data_volume_id
}

output "snapshot_bucket" {
  value = module.data.snapshot_bucket
}

output "snapshot_object_key" {
  description = "S3 object key (path in the bucket) of the latest Raft snapshot. Not a crypto key."
  value       = module.node.snapshot_object_key
}

output "snapshot_s3_uri" {
  value = "s3://${module.data.snapshot_bucket}/${module.node.snapshot_object_key}"
}

output "read_init_command" {
  description = "Plumbing for scripts/vault-ops.sh: the store-specific command that prints the init JSON (root token + recovery keys), run with your own AWS credentials."
  value       = local.read_init
}
