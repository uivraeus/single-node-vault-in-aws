output "instance_id" {
  value = aws_instance.vault.id
}

output "snapshot_object_key" {
  value = local.snapshot_object_key
}
