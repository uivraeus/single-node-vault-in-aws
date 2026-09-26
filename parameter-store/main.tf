module "vault" {
  source = "../modules/vault-node"

  region              = var.region
  name                = var.name
  instance_type       = var.instance_type
  architecture        = var.architecture
  subnet_id           = var.subnet_id
  associate_public_ip = var.associate_public_ip
  store_name          = local.store_name
  store_arn           = local.store_arn
  store_write_action  = local.store_write_action
  store_init_cmd      = local.store_init_cmd
}
