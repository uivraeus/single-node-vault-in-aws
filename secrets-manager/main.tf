# Long-lived: unseal key, data volume, placement. See modules/vault-data.
module "data" {
  source = "../modules/vault-data"

  name      = var.name
  subnet_id = var.subnet_id
}

# Disposable: can be replaced at any time without losing Vault data.
module "node" {
  source = "../modules/vault-node"

  region              = var.region
  name                = var.name
  instance_type       = var.instance_type
  subnet_id           = module.data.subnet_id
  vpc_id              = module.data.vpc_id
  associate_public_ip = var.associate_public_ip
  kms_key_id          = module.data.kms_key_id
  kms_key_arn         = module.data.kms_key_arn
  data_volume_id      = module.data.data_volume_id
  snapshot_bucket     = module.data.snapshot_bucket
  snapshot_bucket_arn = module.data.snapshot_bucket_arn
  store_name          = local.store_name
  store_arn           = local.store_arn
  store_write_action  = local.store_write_action
  store_init_cmd      = local.store_init_cmd
  store_check_action  = local.store_check_action
  store_check_cmd     = local.store_check_cmd
  vault_version       = var.vault_version
  ami_name            = var.ami_name
}
