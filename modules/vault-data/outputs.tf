output "subnet_id" {
  value = data.aws_subnet.selected.id
}

output "vpc_id" {
  value = data.aws_subnet.selected.vpc_id
}

output "kms_key_id" {
  value = aws_kms_key.vault_unseal.key_id
}

output "kms_key_arn" {
  value = aws_kms_key.vault_unseal.arn
}

output "data_volume_id" {
  value = aws_ebs_volume.vault_data.id
}

output "snapshot_bucket" {
  value = aws_s3_bucket.snapshots.id
}

output "snapshot_bucket_arn" {
  value = aws_s3_bucket.snapshots.arn
}
