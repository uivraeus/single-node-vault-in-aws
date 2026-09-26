output "instance_id" {
  value = aws_instance.vault.id
}

output "kms_unseal_key_arn" {
  value = aws_kms_key.vault_unseal.arn
}

output "cmd_shell" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.vault.id}"
}

output "cmd_port_forward" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.vault.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=8200,localPortNumber=8200"
}

output "cmd_bootstrap_log" {
  value = "sudo tail -f /var/log/vault-bootstrap.log"
}